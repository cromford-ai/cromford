#!/bin/bash
# bin/pm-flesh.sh <project> <idea-id> [--force] — BH-7260 (BH-7244.2): the PM
# agent fleshes out ONE roadmap idea into a seven-section brief (Problem,
# Evidence, User and job, Options, Scope cut, Acceptance criteria, Risks) and
# drafts its PRD and mockup. The result lives in the pm_runs row, and the idea
# page (/roadmap/<p>/idea/<id>#pm-flesh) shows it. The idea row is never
# edited. A person runs it, or the idea page's FLESH OUT button starts it
# through bin/pm-flesh-launch.sh.
#
# ONE RUN:
#   1. Arguments: the project is ^[A-Za-z0-9._-]{1,64}$, the idea id is
#      ^[A-Za-z0-9][A-Za-z0-9._:-]{0,79}$. Anything else: rc 2, nothing read.
#   2. run-product's switch (lane_paused run-product <project>) and
#      flags/product-paused-<project> stop it: rc 0, one log line, no read.
#   3. flock -n locks/<project>-product.lock, the lock run-product and
#      pm-groom hold. Held: rc 75 ("busy"), never a wait.
#   4. MODEL=$(lane_model PM_MODEL product.pm <project>). No route: rc 75, no
#      read, no claim, no call.
#   5. Reads: GET /api/settings/ for pm.flesh_timeout_s (60..2400, 900),
#      pm.flesh_result_max_chars (1024..262144, 32768, the worker refuses
#      more) and pm.flesh_prd_max_chars (1024..262144, 131072, the same). A value out of range is one warn line and the fallback. Then
#      GET /api/roadmap/ideas/<id>?project=. No such idea: rc 1, no claim.
#      Any other failed read: rc 75, no claim, no call.
#   6. Evidence: the `ok` rows of the newest products/<project>/*/data-signals.json.
#   7. input_hash = sha256 of the idea {title, note, source, link}, the
#      snapshot hash of that file (else its sha256, else `none`) and the
#      sha256 of prompts/product-stages/pm-flesh.md.
#   8. CLAIM BEFORE THE SPEND: POST /api/pm/claim. No 2xx answer: rc 75 and no
#      call (fail closed for money). Not claimed: a done row prints its
#      stored result (rc 0). An answered row finishes from its stored result
#      at step 11 with draft=unknown and no call. A claimed or failed row is
#      "already billed" (rc 0). --force (a person) re-claims a claimed or
#      failed row. An answered or done row is never re-claimed.
#   9. ONE bin/agent-call.sh call (stage pm, lane run-product, role
#      product.pm, no tools). A non-zero rc, or an answer without exactly the
#      seven headings in order, or with an Evidence id whose status is not
#      ok, or over pm.flesh_result_max_chars, or with PM_FLESH_FAILED as its
#      final line: POST /api/pm/result {status:failed}, one ALERTS line, rc 1
#      (billed, only --force by a person retries).
#  10. POST /api/pm/result {status:answered, result}. From here the row holds
#      the result. A failure: one ALERTS line, rc 1, the row stays claimed
#      (billed).
#  11. bin/draft-proposal.sh <project> <temp dir> drafts the PRD and the
#      mockup (asset key prop:<project>:pmflesh-<run12>). rc 0 is draft=ok,
#      rc 75 skipped, any other rc failed. A failed draft does not stop the run.
#      Its prd.md goes into the row at step 13, so the paid PRD outlives the
#      temp dir. A PRD over pm.flesh_prd_max_chars is cut, with a last line
#      that says so. The screenshots stay under the asset key.
#  12. cost_usd is the sum of the logs/cost.csv rows of <project> whose run_id
#      is pm-flesh:<run id>. The call and the draft run with
#      COST_RUN_ID=pm-flesh:<run id>, so a build, review or triage of
#      <project> that writes rows in the same window is never counted. No row
#      is null.
#  13. POST /api/pm/result {status:done, result_ref, draft, prd, cost_usd}. The
#      row is done only when this answers 200. A failure: one ALERTS line,
#      rc 1, the row stays answered (a re-run finishes it with no call). Else
#      the result is printed, rc 0.
#  14. One line in logs/pm-flesh.log:
#      <ts> [<project>] idea=<id> run=<run id> claim=new|already|resume|billed call=0|1 draft=ok|skipped|failed|unknown rc=<rc>
#
# Temp files live in one mktemp -d dir that a trap removes. Nothing is written
# under state/: the pm_runs row is the only cross-run state.
# It never posts to a client board, never files a ticket and never builds: the
# draft pushes Mission Control assets only.
#
# PM_FLESH_LIB=1 when sourced defines pm_flesh_check (the answer rule) and
# runs nothing. Note: docs/notes/2026-10-30-BH-7260-pm-flesh.md.
set -uo pipefail

# The jq helpers the answer check and the draft share. ulen is the JS length
# (UTF-16 units).
# shellcheck disable=SC2016
PMF_JQ='
def ulen: explode | map(if . > 65535 then 2 else 1 end) | add // 0;
def seven: ["Problem", "Evidence", "User and job", "Options", "Scope cut", "Acceptance criteria", "Risks"];
def section($l; $n):
  ($l | index("## " + $n)) as $a
  | if $a == null then []
    else $l[$a + 1:] | ((map(startswith("## ")) | index(true)) as $e | if $e == null then . else .[0:$e] end) end;
def trimtail: until(length == 0 or (last | test("\\S")); .[:-1]);
'

# pm_flesh_check <answer-file> <data-signals-file> <max-chars>: rc 0 and the
# result (from the first ## heading, PM_FLESH_DONE dropped) on stdout, or rc 1
# and the reason.
pm_flesh_check() {
  local out
  out=$(jq -Rs -c --slurpfile sig "$2" --argjson max "$3" "$PMF_JQ"'
    gsub("\r"; "") | split("\n") as $all
    | (($sig[0].evidence // []) | map(select((.id | type) == "string") | {key: .id, value: (.status // "")}) | from_entries) as $st
    | ([$all[] | select(test("\\S"))] | last // "") as $final
    | if ($final | startswith("PM_FLESH_FAILED")) then {ok: false, why: ("the answer is " + ($final | .[0:200]))}
      else ([range(0; $all | length) | select($all[.] | startswith("## "))] | first) as $h
      | if $h == null then {ok: false, why: "the answer has no ## heading"}
        else ($all[$h:] | trimtail | (if last == "PM_FLESH_DONE" then .[:-1] else . end) | trimtail) as $body
        | [$body[] | select(startswith("## ")) | .[3:]] as $heads
        | ([section($body; "Evidence") | join(" ") | splits("[^A-Za-z0-9._:-]+") | sub("[.:]+$"; "")
            | select(length > 0 and $st[.] != null and $st[.] != "ok")] | unique) as $badev
        | ($body | join("\n")) as $text
        | if $heads != seven then {ok: false, why: ("the headings are [" + ($heads | join("|") | .[0:300]) + "], not the seven in order")}
          elif ($badev | length) > 0 then {ok: false, why: ("Evidence cites " + ($badev | join(", ")) + ", whose status is not ok")}
          elif ($text | ulen) > $max then {ok: false, why: "the answer is over pm.flesh_result_max_chars=\($max)"}
          else {ok: true, result: $text} end end end' "$1" 2>/dev/null) || { echo "the answer could not be read"; return 1; }
  if [ "$(jq -r '.ok' <<<"$out")" = true ]; then jq -r '.result' <<<"$out"; return 0; fi
  jq -r '.why' <<<"$out"; return 1
}

if [ "${PM_FLESH_LIB:-}" = 1 ]; then return 0 2>/dev/null || exit 0; fi

H="${HARNESS:-/root/harness}"
SELF="$(cd "$(dirname "$0")" && pwd)"

usage() { echo "usage: pm-flesh.sh <project> <idea-id> [--force]" >&2; exit 2; }
[ $# -ge 2 ] && [ $# -le 3 ] || usage
P=$1; ID=$2; FORCE=0
if [ $# -eq 3 ]; then [ "$3" = --force ] || usage; FORCE=1; fi
[[ $P =~ ^[A-Za-z0-9._-]{1,64}$ ]] && [ "$P" != . ] && [ "$P" != .. ] || usage
[[ $ID =~ ^[A-Za-z0-9][A-Za-z0-9._:-]{0,79}$ ]] || usage

. "$H/bin/lib/env-path.sh" 2>/dev/null || . "$SELF/lib/env-path.sh" 2>/dev/null \
  || harness_env_dir() { printf '%s\n' "${1:-$H}/env"; }
HENV=$(harness_env_dir "$H")
# shellcheck disable=SC1091
[ -r "$HENV/global.env" ] && { set -a; . "$HENV/global.env" 2>/dev/null; set +a; }
# shellcheck disable=SC1091
{
  . "$H/bin/lib/lane-gate.sh" 2>/dev/null || . "$SELF/lib/lane-gate.sh" 2>/dev/null || true
  . "$SELF/jobs-client.sh" 2>/dev/null || true
  . "$SELF/lib/lane-model.sh" 2>/dev/null || true
  . "$SELF/lib/console-pages.sh" 2>/dev/null || true
}

mkdir -p "$H/logs" "$H/locks" 2>/dev/null
LOG="$H/logs/pm-flesh.log"
log() { printf '%s [%s] %s\n' "$(date -u +%FT%TZ)" "$P" "$*" >> "$LOG"; }
say() { printf 'pm-flesh: %s\n' "$*" >&2; }
# alert <text>: one ALERTS line through bin/alert-line.sh (it stamps the time).
alert() { HARNESS="$H" "$H/bin/alert-line.sh" --project "$P" "[$P] pm-flesh: $*" >/dev/null 2>&1 || true; }
RUN=-; CLAIM=-; CALL=0; DRAFT=-
finish() {
  log "idea=$ID run=$RUN claim=$CLAIM call=$CALL draft=$DRAFT rc=$1"
  exit "$1"
}

# run-product's own switch (all-off, lane-off-run-product, its project row) stops it too.
if command -v lane_paused >/dev/null 2>&1 && lane_paused run-product "$P"; then
  log "run-product is off (${LANE_PAUSED_WHY:-paused}); no flesh-out"; say "run-product is off for $P"; exit 0
fi
if [ -f "$H/flags/product-paused-$P" ]; then log "flags/product-paused-$P is set; no flesh-out"; say "flags/product-paused-$P is set"; exit 0; fi
command -v _jobs_req >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 \
  || { alert "bin/jobs-client.sh or jq is missing; no flesh-out"; say "bin/jobs-client.sh or jq is missing"; exit 75; }

exec 8>"$H/locks/$P-product.lock"
flock -n 8 || { log "the product lock is held (a run-product cycle or a brief is active); busy"; say "busy: the product lock of $P is held"; finish 75; }

command -v lane_model >/dev/null 2>&1 || { say "bin/lib/lane-model.sh is missing"; finish 75; }
MODEL=$(lane_model PM_MODEL product.pm "$P") || { log "no model route for product.pm; no read, no call"; say "no model route for product.pm"; finish 75; }

TMPD=$(mktemp -d "${TMPDIR:-/tmp}/pm-flesh.XXXXXX") || { say "mktemp failed"; finish 75; }
trap 'rm -rf "$TMPD"' EXIT
PE=$(jq -rn --arg p "$P" '$p | @uri')
IE=$(jq -rn --arg i "$ID" '$i | @uri')

# req <out-file> <method> <path> [body]: one jobs request into a file; RC is its rc.
req() { RC=0; _jobs_req "$2" "$3" "${4:-}" > "$1" 2>/dev/null || RC=$?; }

# ── reads ────────────────────────────────────────────────────────────────────
# knob <key> <default> <lo> <hi>: one settings read into KNOB. A failed read is
# rc 75 with no claim and no call. No row is the default. A value that is not
# an integer in lo..hi is one warn line and the default.
knob() {
  local v
  req "$TMPD/knob.json" GET "/api/settings/$1"
  [ "$RC" = 0 ] || [ "$RC" = 2 ] || { log "read failed: GET /api/settings/$1 rc=$RC; no claim, no call"; say "the settings read failed"; finish 75; }
  v=$(jq -r '.setting.value // empty' "$TMPD/knob.json" 2>/dev/null)
  KNOB=$2
  if [ -n "$v" ]; then
    if [[ $v =~ ^[0-9]+$ ]] && [ "$v" -ge "$3" ] && [ "$v" -le "$4" ]; then KNOB=$v
    else log "warn: $1=$v is not an integer in $3..$4; using $2"; fi
  fi
}
# Code fallbacks; each names its settings row (BH-7945).
knob pm.flesh_timeout_s 900 60 2400; TIMEOUT=$KNOB                 # seconds the model call may run
knob pm.flesh_result_max_chars 32768 1024 262144; RMAX=$KNOB      # result characters (the worker reads the same row)
knob pm.flesh_prd_max_chars 131072 1024 262144; PMAX=$KNOB        # PRD characters kept (the worker reads the same row)

req "$TMPD/idea.json" GET "/api/roadmap/ideas/$IE?project=$PE"
if [ "$RC" = 2 ]; then log "no such idea $ID in $P; no claim"; say "no such idea: $ID in $P"; finish 1; fi
if [ "$RC" != 0 ] || ! jq -e '.idea.id | type == "string"' "$TMPD/idea.json" >/dev/null 2>&1; then
  log "read failed: GET /api/roadmap/ideas/$ID rc=$RC; no claim, no call"; say "the idea read failed"; finish 75
fi

# ── evidence and the input hash ──────────────────────────────────────────────
SIG=""
for f in "$H/products/$P"/*/data-signals.json; do [ -f "$f" ] && SIG="$f"; done
SIGF="$TMPD/signals.json"
if [ -n "$SIG" ] && jq -e '.evidence | type == "array"' "$SIG" >/dev/null 2>&1; then
  cp "$SIG" "$SIGF"
  SNAP=$(jq -r '.snapshot_hash // empty | tostring' "$SIG")
  [ -n "$SNAP" ] || SNAP=$(sha256sum < "$SIG" | cut -c1-64)
else
  echo '{"evidence":[]}' > "$SIGF"; SNAP=none
fi
jq -c '[.evidence[] | select(.status == "ok" and (.id | type) == "string") | {evidence_id: .id, source, metric, value, window, link}]' "$SIGF" > "$TMPD/evidence.json"

PROMPT_SRC="$H/prompts/product-stages/pm-flesh.md"
[ -r "$PROMPT_SRC" ] || PROMPT_SRC="$SELF/../prompts/product-stages/pm-flesh.md"
[ -r "$PROMPT_SRC" ] || { alert "prompts/product-stages/pm-flesh.md is missing; no claim, no call"; say "the prompt is missing"; finish 75; }
HASH=$({
  jq -cS '.idea | {title, note: (.note // ""), source, link}' "$TMPD/idea.json"
  printf '%s\n' "$SNAP"
  sha256sum < "$PROMPT_SRC" | cut -c1-64
} | sha256sum | cut -c1-64)

# ── claim before the spend ───────────────────────────────────────────────────
req "$TMPD/claim.json" POST /api/pm/claim "$(jq -nc --arg p "$P" --arg i "$ID" --arg h "$HASH" --arg m "$MODEL" --argjson f "$FORCE" \
  '{project:$p, idea_id:$i, input_hash:$h, model:$m} + (if $f == 1 then {force:true} else {} end)')"
if [ "$RC" != 0 ] || ! jq -e '(.run.id | type) == "string" and (.claimed | type) == "boolean"' "$TMPD/claim.json" >/dev/null 2>&1; then
  log "POST /api/pm/claim rc=$RC; no call"; say "the claim API did not answer; no call"; finish 75
fi
RUN=$(jq -r '.run.id' "$TMPD/claim.json")
[[ $RUN =~ ^[0-9a-f-]{36}$ ]] || { log "POST /api/pm/claim gave run id '${RUN:0:80}', not a UUID; no call"; say "the claim answer is malformed; no call"; RUN=-; finish 75; }
ST=$(jq -r '.run.status' "$TMPD/claim.json")
RESULT="$TMPD/result.md"
if [ "$(jq -r '.claimed' "$TMPD/claim.json")" = true ]; then
  CLAIM=new
else
  case "$ST" in
    done) CLAIM=already; log "run $RUN is done for these inputs; the stored result, no call"
          jq -r '.run.result // ""' "$TMPD/claim.json"; finish 0 ;;
    answered) CLAIM=resume; DRAFT=unknown; log "run $RUN is answered; finish from the stored result, no call"
              jq -j '.run.result // ""' "$TMPD/claim.json" > "$RESULT" ;;
    *) CLAIM=billed; log "run $RUN is $ST; already billed, no call"; say "already billed (run $RUN is $ST); --force re-runs it"; finish 0 ;;
  esac
fi

# fail_run <why>: the run is failed and billed. One ALERTS line, rc 1.
fail_run() {
  req "$TMPD/fail.json" POST /api/pm/result "$(jq -nc --arg p "$P" --arg id "$RUN" --arg e "$1" '{project:$p, id:$id, status:"failed", error:$e}')"
  alert "flesh-out of $ID failed (run $RUN): $1$( [ "$RC" = 0 ] || printf ' (and POST /api/pm/result rc=%s)' "$RC"); billed, --force by a person re-runs it"
  finish 1
}

# The run_id of every cost row this run writes: the cost sum below matches it.
CRID="pm-flesh:$RUN"

# ── the one call, then answered ──────────────────────────────────────────────
if [ "$CLAIM" = new ]; then
  PROMPT="$TMPD/prompt.md"
  {
    cat "$PROMPT_SRC"
    printf '\n## Input\n\nPROJECT: %s\n\nIDEA:\n' "$P"
    jq -c '.idea | {id, title, note: (.note // ""), source, link, lane}' "$TMPD/idea.json"
    printf '\nEVIDENCE (cite these evidence_id values only):\n'; jq -c '.[]' "$TMPD/evidence.json"
  } > "$PROMPT"
  OUT="$TMPD/answer.txt"; : > "$OUT"; rc=0
  CALL=1
  AGENT_CALL_LANE=run-product AGENT_CALL_ROLE=product.pm AGENT_CALL_FP="pm-flesh:$P:$ID:${HASH:0:12}" AGENT_CALL_NO_TOOLS=1 COST_RUN_ID="$CRID" \
    "$H/bin/agent-call.sh" pm "$P" "$MODEL" "$TIMEOUT" "$OUT" "@$PROMPT" </dev/null >/dev/null 2>&1 || rc=$?
  [ "$rc" = 0 ] || fail_run "agent-call rc=$rc"
  CHK=$(pm_flesh_check "$OUT" "$SIGF" "$RMAX") || fail_run "the answer failed the check: $CHK"
  printf '%s' "$CHK" > "$RESULT"
  req "$TMPD/answered.json" POST /api/pm/result "$(jq -nc --arg p "$P" --arg id "$RUN" --rawfile r "$RESULT" '{project:$p, id:$id, status:"answered", result:$r}')"
  if [ "$RC" != 0 ]; then
    alert "POST /api/pm/result (answered) rc=$RC for $ID (run $RUN) after the call; the run stays claimed (billed), --force by a person re-runs it"
    finish 1
  fi
fi

# ── the PRD and the mockup (a new run only; a resume never re-buys them) ─────
if [ "$CLAIM" = new ]; then
  SLUG="pmflesh-${RUN:0:12}"
  mkdir -p "$TMPD/idea"
  jq -n --arg s "$SLUG" --slurpfile i "$TMPD/idea.json" --rawfile r "$RESULT" "$PMF_JQ"'
    ($r | split("\n")) as $l
    | {slug: $s, title: $i[0].idea.title, summary: (section($l; "Problem") | map(select(test("\\S"))) | join(" ")), prd_notes: $r}' > "$TMPD/idea/idea.json"
  drc=0
  COST_RUN_ID="$CRID" "$H/bin/draft-proposal.sh" "$P" "$TMPD/idea" </dev/null >/dev/null 2>&1 || drc=$?
  case "$drc" in 0) DRAFT=ok ;; 75) DRAFT=skipped ;; *) DRAFT=failed ;; esac
  # Keep the paid PRD: it goes into the row, the temp dir does not survive.
  if [ -s "$TMPD/idea/prd.md" ]; then
    jq -Rs --argjson max "$PMAX" "$PMF_JQ"'
      ("\n\n[The PRD was cut at pm.flesh_prd_max_chars=\($max) characters.]") as $note
      | if ulen <= $max then .
        else ($max - ($note | ulen)) as $keep
        | [foreach explode[] as $c (0; . + (if $c > 65535 then 2 else 1 end); select(. <= $keep) | $c)] | implode + $note end' \
      "$TMPD/idea/prd.md" > "$TMPD/prd.json" 2>/dev/null || { log "warn: prd.md could not be read; no PRD kept"; rm -f "$TMPD/prd.json"; }
  fi
fi

# ── the cost of this run ─────────────────────────────────────────────────────
COSTF="$H/logs/cost.csv"
COST=null
if [ -r "$COSTF" ]; then
  COST=$(awk -F, -v p="$P" -v rid="$CRID" '
    NR == 1 { for (i = 1; i <= NF; i++) { if ($i == "project") pc = i; if ($i == "cost_usd") cc = i; if ($i == "run_id") rc = i } next }
    pc && cc && rc && $pc == p && $rc == rid && $cc ~ /^[0-9]+(\.[0-9]+)?$/ { s += $cc; n++ }
    END { if (n) printf "%.6f", s; else print "null" }' "$COSTF")
fi
[[ $COST =~ ^[0-9]+(\.[0-9]+)?$ ]] || COST=null

# ── done ─────────────────────────────────────────────────────────────────────
BASE=$(command -v console_pages_url >/dev/null 2>&1 && console_pages_url) || BASE=""
[ -n "$BASE" ] || BASE=https://console.example.pages.dev
URL="$BASE/roadmap/$PE/idea/$IE#pm-flesh"
[ -s "$TMPD/prd.json" ] || echo null > "$TMPD/prd.json"
req "$TMPD/done.json" POST /api/pm/result "$(jq -nc --arg p "$P" --arg id "$RUN" --arg u "$URL" --arg d "$DRAFT" --argjson c "$COST" --slurpfile prd "$TMPD/prd.json" \
  '{project:$p, id:$id, status:"done", result_ref:$u, draft:$d, cost_usd:$c} + (if $prd[0] == null then {} else {prd: $prd[0]} end)')"
if [ "$RC" != 0 ]; then
  alert "POST /api/pm/result (done) rc=$RC for $ID (run $RUN); the run stays answered, a re-run finishes it with no call"
  finish 1
fi
cat "$RESULT"; echo
finish 0
