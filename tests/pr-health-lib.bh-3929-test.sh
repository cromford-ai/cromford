#!/bin/bash
# tests/pr-health-lib.bh-3929-test.sh — BH-3932 (BH-3929.0): the contract slice
# every other part of the PR-owner split imports.
#
#   L1  ph_knob: settings row > env > default, an outage falls through, 0 binds,
#       a non-number is ignored and named on stderr.
#   L3  ph_ci_only_body: rc 0 only when every BLOCK finding says CI did not run.
#       It will gate a BLOCK clear (#3934), so the negatives matter most.
#   L6  ph_review_covered: covered 0, uncovered 2, outage 1, word filter.
#   L7  the REAL bin/pr-owner-sweep.sh over a four-PR repo, with tracing hooks
#       written over bin/lib/pr-owner/*.sh in the scratch tree: hook order,
#       context vars, knob vars, the superseded skip, a missing lib, and the
#       writes against main's sweep.
#   L8  the stale-replan arm of mc_handoff_owns / mc_resolver_owns.
#   L9  the five settings seeds in worker/jobs/schema.sql.
#   L10 mc_block_ci_step: the stub, its loader, and the conductor's READY-arm
#       call site lifted verbatim from bin/merge-conductor.sh.
#
# gh and curl are PATH shims: no network, no secrets.
# Run: HARNESS_TEST_SANDBOX=1 bash tests/pr-health-lib.bh-3929-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/jobs-schema.sh" && jobs_schema_render || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

command -v jq      >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v python3 >/dev/null || { echo "python3 missing — skipping"; exit 0; }

SLUG=example-org/project-5
P=project-5
SHA_A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
SHA_B=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
mkdir -p "$T/fakebin"

# curl shim. Fixtures are files under $HARNESS/fixture, so a case sets one by
# writing it. Every non-GET is logged as "<METHOD> <path>" (no body: bodies carry
# timestamps), which is what L7h compares between this branch and main.
#   fixture/settings/<key>  the settings row value (absent = 404, no row)
#   fixture/verdict.json    GET /api/verdict?pr=  (absent = 404)
#   fixture/standing.json   GET /api/verdicts?... (absent = {"standing":null})
#   SETTINGS_MODE=500 / JOBS_MODE=500  the outage, per surface or for all
cat > "$T/fakebin/curl" <<'SH'
#!/bin/bash
URL="${!#}"; M=GET; B=""
while [ $# -gt 0 ]; do case "$1" in -X) M="$2"; shift 2 ;; --data-binary) B="$2"; shift 2 ;; *) shift ;; esac; done
P="${URL#"$JOBS_URL"}"
F="$HARNESS/fixture"
# TEST-CHANGE: BH-3936 — a ledger PUT also names its kind, so L7h can tell the
# pr_health row this ticket adds from every other ledger write.
LK=""; [ "${P%%\?*}" = /api/ledger ] && LK=" $(printf '%s' "$B" | jq -r '.kind // "?"' 2>/dev/null)"
[ "$M" != GET ] && printf '%s %s%s\n' "$M" "${P%%\?*}" "$LK" >> "$HARNESS/curl-writes.log"
[ "${JOBS_MODE:-ok}" = 500 ] && { printf '{"error":"boom"}\n500\n'; exit 0; }
case "$M $P" in
  "GET /api/settings/"*)
    [ "${SETTINGS_MODE:-ok}" = 500 ] && { printf '{"error":"boom"}\n500\n'; exit 0; }
    k="${P#/api/settings/}"
    if [ -f "$F/settings/$k" ]; then
      jq -nc --arg k "$k" --arg v "$(cat "$F/settings/$k")" '{setting:{key:$k,value:$v}}'; echo 200
    else printf '{"error":"no such setting"}\n404\n'; fi ;;
  "GET /api/verdict?"*)
    if [ -f "$F/verdict.json" ]; then cat "$F/verdict.json"; echo; echo 200
    else printf '{"error":"no job"}\n404\n'; fi ;;
  "GET /api/verdicts?"*)
    if [ -f "$F/standing.json" ]; then cat "$F/standing.json"; echo; echo 200
    else printf '{"standing":null,"rows":[]}\n200\n'; fi ;;
  "GET /api/jobs"*)  printf '%s\n200\n' "$(cat "$F/jobs.json" 2>/dev/null || echo '{"jobs":[]}')" ;;
  "GET /api/queue"*) printf '{"queue":[]}\n200\n' ;;
  *)                 printf '{"ok":true}\n200\n' ;;
esac
SH
chmod +x "$T/fakebin/curl"
export PATH="$T/fakebin:$PATH"

# ============================================================================
# The library tree: L1, L3, L6 run the lib in THIS shell, so PH_KNOB_SRC is
# readable (in $(...) it is lost by design).
# ============================================================================
L="$T/lib"
mkdir -p "$L/bin/lib/jobs" "$L/logs" "$L/fixture/settings" "$L/env"
# TEST-CHANGE: BH-3933 r3 — closures, not a hand list (D46).
scratch_install_closure bin/jobs-client.sh "$L" >/dev/null || { echo "closure install failed"; exit 1; }
scratch_install_closure bin/lib/pr-health.sh "$L" >/dev/null || { echo "closure install failed"; exit 1; }
export HARNESS="$L" HARNESS_SECRET=s3cret JOBS_URL=https://jobs.test JOBS_RETRIES=0
# shellcheck source=/dev/null
. "$L/bin/jobs-client.sh" 2>/dev/null
# shellcheck source=bin/lib/pr-health.sh
[ -r "$L/bin/lib/pr-health.sh" ] && . "$L/bin/lib/pr-health.sh"
command -v ph_knob >/dev/null 2>&1 || bad "L0 bin/lib/pr-health.sh is missing or defines no ph_knob"

FX="$L/fixture"
knob() { # knob <key> <ENV> <default> -> sets KV, KSRC, KERR
  PH_KNOB_SRC=""
  ph_knob "$@" > "$T/knob.out" 2> "$T/knob.err"; KRC=$?
  KV=$(cat "$T/knob.out"); KSRC="$PH_KNOB_SRC"; KERR=$(cat "$T/knob.err")
}

# ---------- L1 ph_knob --------------------------------------------------------
rm -f "$FX"/settings/*
echo 12 > "$FX/settings/pr_stale.rebase_hours"
export PR_STALE_REBASE_HOURS=30
knob pr_stale.rebase_hours PR_STALE_REBASE_HOURS 24
[ "$KRC/$KV/$KSRC" = "0/12/row" ] && ok || bad "L1a the settings row (12) must beat env (30) and default (24): rc=$KRC v=$KV src=$KSRC"
rm -f "$FX/settings/pr_stale.rebase_hours"
knob pr_stale.rebase_hours PR_STALE_REBASE_HOURS 24
[ "$KV/$KSRC" = "30/env" ] && ok || bad "L1a with no row the env (30) must win: v=$KV src=$KSRC"
unset PR_STALE_REBASE_HOURS
knob pr_stale.rebase_hours PR_STALE_REBASE_HOURS 24
[ "$KV/$KSRC" = "24/default" ] && ok || bad "L1a with neither the default (24) must win: v=$KV src=$KSRC"

echo 12 > "$FX/settings/pr_stale.rebase_hours"
export PR_STALE_REBASE_HOURS=30
SETTINGS_MODE=500 knob pr_stale.rebase_hours PR_STALE_REBASE_HOURS 24
[ "$KV/$KSRC" = "30/outage" ] && ok || bad "L1b a settings outage must fall to env and say outage: v=$KV src=$KSRC"
[ -n "$KERR" ] && ok || bad "L1b an outage must leave a stderr note"
unset PR_STALE_REBASE_HOURS
SETTINGS_MODE=500 knob pr_stale.rebase_hours PR_STALE_REBASE_HOURS 24
[ "$KV/$KSRC" = "24/outage" ] && ok || bad "L1b an outage with no env falls to the default, still outage: v=$KV src=$KSRC"
( unset -f setting_get; PH_KNOB_SRC=""; v=$(ph_knob pr_stale.rebase_hours PR_STALE_REBASE_HOURS 24 2>/dev/null)
  ph_knob pr_stale.rebase_hours PR_STALE_REBASE_HOURS 24 >/dev/null 2>&1
  [ "$v/$PH_KNOB_SRC" = "24/outage" ] ) && ok || bad "L1b no setting_get at all is an outage, not a crash"

echo 0 > "$FX/settings/pr_stale.rebase_hours"
export PR_STALE_REBASE_HOURS=30
knob pr_stale.rebase_hours PR_STALE_REBASE_HOURS 24
[ "$KV/$KSRC" = "0/row" ] && ok || bad "L1c a row of 0 binds 0 (zero-means-off): v=$KV src=$KSRC"

echo abc > "$FX/settings/pr_stale.rebase_hours"
knob pr_stale.rebase_hours PR_STALE_REBASE_HOURS 24
[ "$KV/$KSRC" = "30/env" ] && ok || bad "L1d a row of abc is ignored, env wins: v=$KV src=$KSRC"
grep -q abc <<<"$KERR" && grep -q pr_stale.rebase_hours <<<"$KERR" && ok || bad "L1d the ignored row must be named on stderr: '$KERR'"
rm -f "$FX/settings/pr_stale.rebase_hours"
export PR_STALE_REBASE_HOURS=abc
knob pr_stale.rebase_hours PR_STALE_REBASE_HOURS 24
[ "$KV/$KSRC" = "24/default" ] && ok || bad "L1d env abc is ignored, default wins: v=$KV src=$KSRC"
grep -q PR_STALE_REBASE_HOURS <<<"$KERR" && ok || bad "L1d the ignored env must be named on stderr: '$KERR'"
unset PR_STALE_REBASE_HOURS
knob pr_stale.rebase_hours PR_STALE_REBASE_HOURS 24
[ -z "$KERR" ] && ok || bad "L1 a clean default read prints nothing on stderr: '$KERR'"

# ---------- L3 ph_ci_only_body ------------------------------------------------
yes_ci() { if ph_ci_only_body "$2"; then ok; else bad "L3 rc 0 expected — $1"; fi; }
no_ci()  { if ph_ci_only_body "$2"; then bad "L3 rc 1 expected — $1"; else ok; fi; }
yes_ci "ticket line"          "- [BLOCK] the Jobs-worker CI job did not run on this head"
yes_ci "workflow cancelled"   "- [BLOCK] The CI workflow was cancelled on this head"
yes_ci "paragraph, no CI run" $'Findings\n\nBLOCK — no CI run on this head.\n\nVERDICT: BLOCK'
yes_ci "upper case"           "- [BLOCK] THE CI JOB DID NOT RUN ON THIS HEAD"
yes_ci "lower case"           "- [block] the ci workflow never ran"
yes_ci "two CI-only lines"    $'- [BLOCK] the CI job did not run\n- [BLOCK] GitHub Actions workflow was skipped\n- [NIT] typo'
no_ci  "a second line with a path:line" $'- [BLOCK] the Jobs-worker CI job did not run on this head\n- [BLOCK] bin/x.sh:12: drops the error'
no_ci  "empty"                ""
no_ci  "ran and failed, names a file"   "- [BLOCK] the CI job ran and failed on tests/x-test.sh"
no_ci  "path:line + skipped check"      "- [BLOCK] bin/x.sh:12: the check for an empty head was skipped"
no_ci  "cron job skipped a lock check"  "- [BLOCK] the cron job skipped its lock check, so two ticks race"
no_ci  "one CI line + one RLS line"     $'- [BLOCK] workflow did not run\n- [BLOCK] missing RLS on new table'
no_ci  "paragraph with a file token"    "BLOCK: CI did not run, and bin/lib/x.sh drops the error"
no_ci  "APPROVE, no BLOCK"              "VERDICT: APPROVE"
no_ci  "job did not run, no CI word"    "- [BLOCK] job did not run"
no_ci  "skipped check names src/a.ts"   "- [BLOCK] the check for null was skipped in src/a.ts"
no_ci  "tests did not run, names a file" "- [BLOCK] tests did not run because bin/foo.sh exits early"
no_ci  "the plan's CI + bin/x.sh:12 pair" $'- [BLOCK] CI did not run on this head\n- [BLOCK] bin/x.sh:12 returns 0 on error'
# BH-3932 review: three shapes that answered rc 0 before the fail-closed rule.
no_ci  "numbered finding after the CI paragraph" $'BLOCK: CI did not run on this head.\n\n1. [BLOCK] bin/x.sh:12 drops the error'
no_ci  "two bold [BLOCK] findings, one paragraph" $'**[BLOCK]** CI did not run.\n**[BLOCK]** missing RLS on the new table'
no_ci  "prose BLOCK beside a - [BLOCK] line"     $'- [BLOCK] CI did not run\n\nBLOCK: missing RLS on table x'
no_ci  "a lone bold [BLOCK], unparsed shape"     "**[BLOCK]** CI did not run on this head."
no_ci  "list item inside the CI paragraph"       $'BLOCK: CI did not run on this head.\n- missing RLS on table x'
no_ci  "second prose BLOCK paragraph"            $'BLOCK: CI did not run.\n\nBLOCK: missing RLS on table x'
yes_ci "verdict line beside the bullets"         $'- [BLOCK] the CI workflow did not run\n\n**VERDICT: BLOCK**'
# KNOWN GAP, not asserted: as a [BLOCK] line, "CI passed, but the migration did
# not run on prod" is CI-named and matches the vocabulary, so it answers rc 0
# today. #3934 adds the finer rule before anything clears a BLOCK on this answer.
ph_ci_only_body "- [BLOCK] CI passed, but the migration did not run on prod" \
  && echo "KNOWN-GAP L3: '- [BLOCK] CI passed, but the migration did not run on prod' answers rc 0 (#3934 owns the fix)"

# ---------- L6 ph_review_covered ----------------------------------------------
vfix() { # vfix <verdict> <reviewed_sha>
  jq -nc --arg v "$1" --arg s "$2" \
    '{verdict:$v, artifacts:[{artifact_kind:"verdict", detail:({reviewed_sha:$s, settled:true, source:"lead"}|tojson)}]}' > "$FX/verdict.json"
}
sfix() { jq -nc --arg v "$1" '{standing:{verdict:$v,source:"lead",id:7,created_at:"2026-10-03T00:00:00Z"}}' > "$FX/standing.json"; }
covered() { ph_review_covered "$@" >/dev/null 2>&1; echo $?; }
rm -f "$FX/verdict.json" "$FX/standing.json"
vfix APPROVE "$SHA_A"
[ "$(covered "$SLUG" 41 "$SHA_A")" = 0 ] && ok || bad "L6a a verdict bound to this head covers it"
vfix APPROVE "$SHA_B"
[ "$(covered "$SLUG" 41 "$SHA_A")" = 2 ] && ok || bad "L6b a verdict on another sha with no standing row is rc 2: $(covered "$SLUG" 41 "$SHA_A")"
[ "$(JOBS_MODE=500 covered "$SLUG" 41 "$SHA_A")" = 1 ] && ok || bad "L6c a jobs outage is rc 1, never 'not covered': $(JOBS_MODE=500 covered "$SLUG" 41 "$SHA_A")"
vfix BLOCK "$SHA_A"; sfix BLOCK
[ "$(covered "$SLUG" 41 "$SHA_A" APPROVE)" = 2 ] && ok || bad "L6d APPROVE asked, a BLOCK stands in both sources: rc 2 expected, got $(covered "$SLUG" 41 "$SHA_A" APPROVE)"
[ "$(covered "$SLUG" 41 "$SHA_A" BLOCK)" = 0 ] && ok || bad "L6d the word filter must still match its own word"
rm -f "$FX/verdict.json"; sfix MERGE
[ "$(covered "$SLUG" 41 "$SHA_A")" = 0 ] && ok || bad "L6e a standing MERGE row with no word covers the head"
rm -f "$FX/standing.json"

# ============================================================================
# L7 — the real sweep. A scratch harness shaped like tests/pr-owner-sweep-test.sh.
# ============================================================================
D=86400
NOWISO() { date -u -d "@$(( $(date +%s) - ${1:-0} ))" '+%Y-%m-%dT%H:%M:%SZ'; }
mk_tree() { # mk_tree <dir> <sweep-file>
  local H="$1"
  mkdir -p "$H/bin/lib/jobs" "$H/logs" "$H/state/merge-conductor" "$H/state/pr-owners" "$H/locks" "$H/flags" "$H/env" "$H/fixture"
  cp "$2" "$H/bin/pr-owner-sweep.sh"; chmod +x "$H/bin/pr-owner-sweep.sh"
  # TEST-CHANGE: BH-3933 r3 — the sweep's libs (gh-rest.sh for its REST writes
  # included) arrive with its closure, not a hand list (D46). The sweep copied
  # above is kept: the install never overwrites.
  scratch_install_closure bin/pr-owner-sweep.sh "$H" >/dev/null || { echo "closure install failed"; exit 1; }
  scratch_install_closure bin/jobs-client.sh "$H" >/dev/null || { echo "closure install failed"; exit 1; }
  cp "$DIR/bin/alert-line.sh" "$H/bin/"
  scratch_install_closure bin/lib/hub-box.sh "$H" >/dev/null || exit 1; echo box-hub > "$H/state/box-name"; : > "$H/state/merge-conductor/pr-state.tsv"; export HUB_BOX_NAME=box-hub  # TEST-CHANGE: BH-5124 — the conductor file is read only on the conductor's box, and only when it exists
  ln -sf "$DIR/bin/fleet-conf.sh" "$H/bin/fleet-conf.sh"
  printf 'HARNESS_SECRET=s3cret\nJOBS_URL=https://jobs.test\nPR_STALE_REPLAN_DAYS=7\n' > "$H/env/global.env"
  printf '#!/bin/bash\necho box-project-5-1\n' > "$H/bin/box-for.sh"
  printf '#!/bin/bash\nexit 0\n' > "$H/bin/lane-alert.sh"
  chmod +x "$H/bin/box-for.sh" "$H/bin/lane-alert.sh"
  # #900 OWNED (running ledger job), #902 EXTERNAL and a draft, #906 ORPHAN whose
  # key merged in #1200 (close-duplicate), #909 plain ORPHAN (hand-back).
  cat > "$H/fixture/open.json" <<JSON
[
 {"number":900,"title":"TK-900: in flight","headRefName":"ticket/TK-900","headRefOid":"9000000000000000000000000000000000000000","author":{"login":"operator"},
  "labels":[],"body":"","mergeable":"MERGEABLE","updatedAt":"$(NOWISO $((2*D)))","createdAt":"2026-09-01T00:00:00Z","url":"https://github.com/$SLUG/pull/900","isDraft":false},
 {"number":902,"title":"Add the CSV mapper","headRefName":"reviewer-1/csv-mapper","headRefOid":"9020000000000000000000000000000000000000","author":{"login":"reviewer-1-partner"},
  "labels":[],"body":"","mergeable":"CONFLICTING","updatedAt":"$(NOWISO $((90*D)))","createdAt":"2026-07-01T00:00:00Z","url":"https://github.com/$SLUG/pull/902","isDraft":true},
 {"number":906,"title":"TK-906: carry-forward","headRefName":"ticket/TK-906","headRefOid":"9060000000000000000000000000000000000000","author":{"login":"operator"},
  "labels":[],"body":"","mergeable":"MERGEABLE","updatedAt":"$(NOWISO $((30*D)))","createdAt":"2026-08-01T00:00:00Z","url":"https://github.com/$SLUG/pull/906","isDraft":false},
 {"number":909,"title":"TK-909: the plain orphan","headRefName":"ticket/TK-909","headRefOid":"9090000000000000000000000000000000000000","author":{"login":"operator"},
  "labels":[],"body":"","mergeable":"MERGEABLE","updatedAt":"$(NOWISO $((30*D)))","createdAt":"2026-08-02T00:00:00Z","url":"https://github.com/$SLUG/pull/909","isDraft":false}
]
JSON
  echo '[{"number":1200,"title":"TK-906: carry-forward","headRefName":"ticket/TK-906","url":"https://github.com/'"$SLUG"'/pull/1200","mergedAt":"'"$(NOWISO $((5*D)))"'"}]' > "$H/fixture/merged.json"
  echo '{"jobs":[{"id":"build-project-5-TK-900-1","ticket_id":"TK-900","kind":"build","status":"running","meta":"{\"key\":\"TK-900\"}"}]}' > "$H/fixture/jobs.json"
  mkdir -p "$H/fixture/settings"; echo 12 > "$H/fixture/settings/pr_stale.rebase_hours"
}
# gh shim: reads from the fixture, records every write.
cat > "$T/fakebin/gh" <<'SH'
#!/bin/bash
case "$1 $2" in
  "api rate_limit")
    printf '{"resources":{"core":{"remaining":4000,"limit":5000,"reset":%s},"graphql":{"remaining":4000,"limit":5000,"reset":%s}}}\n' "$(date +%s)" "$(date +%s)"; exit 0 ;;
  "api repos/"*) echo 1234; exit 0 ;;
esac
case "$*" in
  # TEST-CHANGE: BH-6929 — po_dup_guard runs before every duplicate close: the open list carries latestReviews as gh writes it when asked, and the guard's reads (issue events, PR comments, compare) answer clean.
  *"pr list"*"--state open"*)   jq 'map(.latestReviews //= [])' "$HARNESS/fixture/open.json" ;;
  *"pr list"*"--state merged"*) cat "$HARNESS/fixture/merged.json" ;;
  *"pr comment"*|*"pr close"*|*"pr edit"*|*"api -X"*) printf '%s\n' "$*" >> "$HARNESS/gh-writes.log" ;;
  # TEST-CHANGE: BH-3933 — a REST write answers with a status line (bin/lib/gh-rest.sh
  # judges it), and the close's re-read of the PR answers closed.
  *"api -i -X P"*) printf '%s\n' "$*" >> "$HARNESS/gh-writes.log"; printf 'HTTP/1.1 200 OK\r\n\r\n{}\n' ;;
  # TEST-CHANGE: BH-6815 — the close-duplicate arm reads the PR's file list and
  # main's sha first (po_done_close_guard); an empty list = nothing left to ship.
  *"api -i -X GET repos/"*"/pulls/"*"/files"*) printf 'HTTP/1.1 200 OK\r\n\r\n[]\n' ;;
  *"api -i -X GET repos/"*"/commits/HEAD"*) printf 'HTTP/1.1 200 OK\r\n\r\n{"sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}\n' ;;
  *"api -i -X GET repos/"*"/pulls/"*) printf 'HTTP/1.1 200 OK\r\n\r\n{"state":"closed","merged_at":null}\n' ;;
  *"api -i -X GET repos/"*"/issues/"*"/events"*|*"api -i -X GET repos/"*"/issues/"*"/comments"*) printf 'HTTP/1.1 200 OK\r\n\r\n[]\n' ;;
  *"api -i -X GET repos/"*"/compare/"*) printf 'HTTP/1.1 200 OK\r\n\r\n{"status":"diverged"}\n' ;;
  *) exit 1 ;;
esac
SH
chmod +x "$T/fakebin/gh"

# The tracing hooks, written over the shipped stubs. They record, they decline.
trace_hooks() { # trace_hooks <tree>
  local d="$1/bin/lib/pr-owner"; mkdir -p "$d"
  cat > "$d/superseded.sh" <<'SH'
po_superseded() { echo "S $PO_NUM" >> "$HARNESS/trace.log"; [ "${TRACE_SUPERSEDE:-}" = "$PO_NUM" ] && return 0; return 2; }
SH
  cat > "$d/enroll.sh" <<'SH'
po_enroll() {
  echo "E $PO_NUM" >> "$HARNESS/trace.log"
  echo "CTX $PO_NUM|$PO_CLASS|$PO_AUTHOR|$PO_HEAD|$PO_DRAFT|$PO_OWNED|$PO_KEY|$PO_MERGEABLE|$PO_CREATED|$PO_PROJECT|$PO_SLUG" >> "$HARNESS/ctx.log"
  echo "KNOB $PO_STALE_REBASE_H $PO_STALE_REPLAN_D $PO_STALE_CLOSE_D $PO_ENROLL_EXTERNAL $PO_OWNERLESS_ALERT_H" >> "$HARNESS/ctx.log"
  return 2; }
SH
  cat > "$d/stale.sh" <<'SH'
po_stale() { echo "T $PO_NUM" >> "$HARNESS/trace.log"; return 2; }
SH
  cat > "$d/health.sh" <<'SH'
po_health_add() { echo "H $PO_NUM" >> "$HARNESS/trace.log"; return 2; }
po_health_flush() { echo "F $1 $2" >> "$HARNESS/trace.log"; return 0; }
SH
}
# The registry gate's own heartbeat (bin/lib/lane-gate.sh _lg_liveness) is the
# ONE write this slice adds, on purpose (plan A1): every wired lane posts it. It
# is not a hook write, so the write comparisons below read everything else.
# TEST-CHANGE: BH-3936 — the filled health hook writes one ledgers row
# kind=pr_health per repo (po_health_flush); that is the ticket's ask, and
# H5 in tests/daily-digest-pr-health.bh-3929-test.sh pins it. Every other
# write still has to match main's.
nogate() { grep -v -e '^POST /api/lanes/liveness$' -e '^PUT /api/ledger pr_health$' "$1" 2>/dev/null; }
sweep() { # sweep <tree> [env...] -> rc in SRC
  local H="$1"; shift
  rm -f "$H/trace.log" "$H/ctx.log" "$H/gh-writes.log" "$H/curl-writes.log"
  scratch_rm "$H/state/pr-owners" || exit 1; scratch_rm "$H/locks" || exit 1; scratch_rm "$H/logs" || exit 1
  mkdir -p "$H/state/pr-owners" "$H/locks" "$H/logs"
  env HARNESS="$H" FLEET_CONF="$DIR/fleet.conf" GH_TOKEN=x GH_BUDGET_TTL_S=0 "$@" \
    bash "$H/bin/pr-owner-sweep.sh" --repo "$SLUG" > "$H/out.txt" 2>"$H/err.txt"
  SRC=$?
}

A="$T/a"
mk_tree "$A" "$DIR/bin/pr-owner-sweep.sh"; trace_hooks "$A"
sweep "$A"
EXPECT="S 900
E 900
T 900
H 900
S 902
E 902
T 902
H 902
S 906
E 906
T 906
H 906
S 909
E 909
T 909
H 909
F $P $SLUG"
[ "$SRC" = 0 ] && ok || bad "L7 the sweep must exit 0 (rc=$SRC): $(head -3 "$A/err.txt")"
[ "$(cat "$A/trace.log" 2>/dev/null)" = "$EXPECT" ] && ok \
  || bad "L7f each hook once per PR, S E T H, then one F per repo — got: $(tr '\n' ' ' < "$A/trace.log" 2>/dev/null)"
grep -q "^CTX 909|ORPHAN|operator|9090000000000000000000000000000000000000|0|0|TK-909|MERGEABLE|2026-08-02T00:00:00Z|$P|$SLUG\$" "$A/ctx.log" && ok \
  || bad "L7e ORPHAN #909 context vars: $(grep 'CTX 909' "$A/ctx.log")"
grep -q "^CTX 902|EXTERNAL|reviewer-1-partner|9020000000000000000000000000000000000000|1|0|-|CONFLICTING|2026-07-01T00:00:00Z|$P|$SLUG\$" "$A/ctx.log" && ok \
  || bad "L7e EXTERNAL draft #902 context vars: $(grep 'CTX 902' "$A/ctx.log")"
grep -q "^CTX 900|OWNED|operator|9000000000000000000000000000000000000000|0|1|TK-900|" "$A/ctx.log" && ok \
  || bad "L7e OWNED #900 must carry PO_OWNED=1: $(grep 'CTX 900' "$A/ctx.log")"
[ "$(grep -c '^KNOB 12 7 10 1 24$' "$A/ctx.log")" = 4 ] && ok \
  || bad "L7d knob vars (row 12, env 7, defaults 10 1 24) on every PR: $(grep KNOB "$A/ctx.log" | sort -u | tr '\n' ' ')"
grep -q "PATCH repos/$SLUG/pulls/906 " "$A/gh-writes.log" 2>/dev/null && ok || bad "L7 the ORPHAN arms still run after the hooks decline: $(cat "$A/gh-writes.log" 2>/dev/null)"

# L7g — superseded rc 0 skips the rest for that PR only, including its ORPHAN arm.
sweep "$A" TRACE_SUPERSEDE=909
[ "$(grep ' 909$' "$A/trace.log" | tr '\n' ' ')" = "S 909 " ] && ok \
  || bad "L7g a superseded PR runs S and nothing else: $(grep ' 909$' "$A/trace.log" | tr '\n' ' ')"
[ "$(grep -c ' 906$' "$A/trace.log")" = 4 ] && ok || bad "L7g the skip is per PR, #906 still runs all four"
grep -q 'handed-back=-' "$A/logs/pr-owner-sweep.log" && ok \
  || bad "L7g a superseded PR's ORPHAN hand-back must not run: $(grep 'open=' "$A/logs/pr-owner-sweep.log")"

# L7c — a missing hook lib ends the run before anything leaves the box.
rm -f "$A/bin/lib/pr-owner/stale.sh"
sweep "$A"
[ "$SRC" = 1 ] && ok || bad "L7c a missing bin/lib/pr-owner/stale.sh must exit 1, got $SRC"
[ ! -s "$A/gh-writes.log" ] && [ -z "$(nogate "$A/curl-writes.log")" ] && ok \
  || bad "L7c no write with a missing lib: gh=$(cat "$A/gh-writes.log" 2>/dev/null) curl=$(nogate "$A/curl-writes.log")"

# L7b — the SHIPPED stubs decline, flush is a no-op.
( . "$DIR/bin/lib/pr-owner/enroll.sh" && . "$DIR/bin/lib/pr-owner/superseded.sh" && . "$DIR/bin/lib/pr-owner/stale.sh" && . "$DIR/bin/lib/pr-owner/health.sh" || exit 9
  po_superseded; [ $? = 2 ] || exit 1; po_enroll; [ $? = 2 ] || exit 2; po_stale; [ $? = 2 ] || exit 3
  po_health_add; [ $? = 2 ] || exit 4; po_health_flush "$P" "$SLUG" || exit 5 ) 2>/dev/null
R=$?; [ "$R" = 0 ] && ok || bad "L7b the shipped stubs return 2 and flush returns 0 (failed at step $R)"

# L7h — with the SHIPPED stubs, this branch writes exactly what main's sweep writes.
# TEST-CHANGE: BH-3933 — the sweep's GitHub writes moved from `gh pr comment|close|
# edit` to REST, so main and this branch spell the SAME write differently. Both
# logs are reduced to "<write> <PR>" (comment / close / label) before the compare,
# which still fails on a write added, dropped, reordered or aimed at another PR.
ghw() { sed -E 's#^pr comment ([0-9]+).*#comment \1#; s#^pr close ([0-9]+).*#close \1#;
  s#^pr edit ([0-9]+).*--add-label.*#label \1#; s#^api -i -X POST repos/[^/]+/[^/]+/issues/([0-9]+)/comments.*#comment \1#;
  s#^api -i -X PATCH repos/[^/]+/[^/]+/pulls/([0-9]+) .*#close \1#; s#^api -i -X POST repos/[^/]+/[^/]+/issues/([0-9]+)/labels.*#label \1#' "$1" 2>/dev/null \
  | grep -E '^(comment|close|label) [0-9]+$'; }
Bt="$T/b"; Mt="$T/m"
mk_tree "$Bt" "$DIR/bin/pr-owner-sweep.sh"
MAINREF=""
for r in origin/main main; do git -C "$DIR" rev-parse -q --verify "$r:bin/pr-owner-sweep.sh" >/dev/null 2>&1 && { MAINREF=$r; break; }; done
if [ -n "$MAINREF" ]; then
  git -C "$DIR" show "$MAINREF:bin/pr-owner-sweep.sh" > "$T/main-sweep.sh"
  mk_tree "$Mt" "$T/main-sweep.sh"
  sweep "$Bt"; BRC=$SRC; sweep "$Mt"; MRC=$SRC
  [ "$BRC/$MRC" = "0/0" ] && ok || bad "L7h both sweeps exit 0 (branch=$BRC main=$MRC)"
  if [ -n "$(ghw "$Mt/gh-writes.log")" ] && [ "$(ghw "$Bt/gh-writes.log")" = "$(ghw "$Mt/gh-writes.log")" ]; then ok
  else bad "L7h gh writes differ from main: branch=[$(cat "$Bt/gh-writes.log" 2>/dev/null)] main=[$(cat "$Mt/gh-writes.log" 2>/dev/null)]"; fi
  if [ -s "$Mt/curl-writes.log" ] && [ "$(nogate "$Bt/curl-writes.log")" = "$(nogate "$Mt/curl-writes.log")" ]; then ok
  else bad "L7h jobs-API writes differ from main: branch=[$(tr '\n' ' ' < "$Bt/curl-writes.log" 2>/dev/null)] main=[$(tr '\n' ' ' < "$Mt/curl-writes.log" 2>/dev/null)]"; fi
  grep -qx 'POST /api/lanes/liveness' "$Bt/curl-writes.log" && ok || bad "L7h the sweep must now pass the registry gate (no liveness row posted)"
else
  echo "SKIP L7h: no main ref in this checkout to diff the sweep against"
fi

# ---------- L8 the stale-replan hand-off --------------------------------------
( export HARNESS="$T/mc"; mkdir -p "$HARNESS/logs"
  . "$DIR/bin/lib/merge-conductor-lib.sh" >/dev/null 2>&1
  mc_handoff_owns "stale-replan: no touch 5d" || exit 1
  mc_resolver_owns "stale-replan: no touch 5d" || exit 2
  mc_handoff_owns "stale-nothing" && exit 3
  exit 0 ); R=$?
[ "$R" = 0 ] && ok || bad "L8 stale-replan* must be a hand-off AND resolver-owned, and only that prefix (step $R)"

# ---------- L9 the settings seeds ---------------------------------------------
SEEDS=$(python3 - "$DIR/worker/jobs/schema.sql" <<'PY' 2>&1
import sqlite3, sys
db = sqlite3.connect(":memory:")
db.executescript(open(sys.argv[1]).read())
for k, v, n in db.execute("SELECT key,value,note FROM settings WHERE key LIKE 'pr_stale.%' OR key LIKE 'pr_owner.%' ORDER BY key"):
    print("%s=%s %s" % (k, v, "BH-3929" if n.startswith("BH-3929:") else "NO-NOTE"))
PY
)
[ "$SEEDS" = "pr_owner.enroll_external=1 BH-3929
pr_owner.ownerless_alert_hours=24 BH-3929
pr_stale.close_days=10 BH-3929
pr_stale.rebase_hours=24 BH-3929
pr_stale.replan_days=5 BH-3929" ] && ok || bad "L9 the five seeds load from schema.sql with BH-3929 notes: $SEEDS"

# ---------- L10 mc_block_ci_step ----------------------------------------------
( . "$DIR/bin/lib/mc/block-ci.sh" 2>/dev/null || exit 9; mc_block_ci_step a/b 1 sha url id ""; [ $? = 2 ] ) \
  && ok || bad "L10 the shipped mc_block_ci_step stub returns 2"
( export HARNESS="$T/mc"; . "$DIR/bin/lib/merge-conductor-lib.sh" >/dev/null 2>&1; command -v mc_block_ci_step >/dev/null ) \
  && ok || bad "L10 bin/lib/merge-conductor-lib.sh must load mc_block_ci_step"
# The READY arm, lifted verbatim from the shipped conductor and run as a
# function: a hook that answers 0 must not turn the refusal into a merge.
BLK=$(sed -n '/# >>> block gate$/,/# <<< block gate$/p' "$DIR/bin/merge-conductor.sh")
[ -n "$BLK" ] || bad "L10 the >>> block gate markers are gone from bin/merge-conductor.sh"
ready_arm() {
  local SLUG=example-org/demo-os NUM=41 HEAD="$SHA_A" URL=https://github.com/example-org/demo-os/pull/41
  local P=demo KEY="example-org/demo-os#41" PROVIDER=native REC=x BR=x H="$T/mc"
  eval "$BLK"
  echo FELL-THROUGH
}
bg_scan()    { printf 'https://x/c/9\tlead\t2026-10-03T00:00:00Z\t%s\n' "${BG_FAKE_ID:-9001}"; return "${BG_FAKE_RC:-1}"; }
bg_enforce() { return 0; }
bg_why()     { echo why; }
bg_reason()  { echo reason; }
bg_refuse()  { echo REFUSED >> "$T/l10.log"; return 0; }
mc_log()     { :; }
mc_block_ci_step() { printf 'HOOK %s\n' "$*" >> "$T/l10.log"; return 0; }
rm -f "$T/l10.log"; OUT=$(ready_arm)
[ -z "$OUT" ] && ok || bad "L10 a refusal must return before the merge, even when the hook answers 0 (got: $OUT)"
[ "$(cat "$T/l10.log" 2>/dev/null)" = "REFUSED
HOOK example-org/demo-os 41 $SHA_A https://github.com/example-org/demo-os/pull/41 9001 " ] && ok \
  || bad "L10 the hook runs after the refusal with slug num head url block-id and an empty body: $(cat "$T/l10.log" 2>/dev/null)"
rm -f "$T/l10.log"; OUT=$(BG_FAKE_RC=2 ready_arm)
[ ! -s "$T/l10.log" ] && ok || bad "L10 the rc 2 (unreadable) arm must not call the hook: $(cat "$T/l10.log")"
rm -f "$T/l10.log"; bg_enforce() { return 1; }; OUT=$(ready_arm)
[ ! -s "$T/l10.log" ] && [ "$OUT" = FELL-THROUGH ] && ok || bad "L10 the warn-only arm must not call the hook: $(cat "$T/l10.log")"

echo "pr-health-lib.bh-3929: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
