#!/bin/bash
# tests/plan-cross-repo-read.bh-5910-test.sh — BH-5910: a plan that declares a
# read of a repo this build's GitHub tokens cannot read stops at PLAN with
# `PLAN_BLOCKED cross-repo-read <repo>`, not at EXECUTE with an empty diff.
#
# The planner is asked (xrepo_plan_note, in the plan prompt) to write one line
# `CROSS-REPO-READ: <owner>/<repo>` per repo it will copy or read code from.
# Only those lines are checked: plans name other repos in prose all the time.
# A repo is "cannot read" only when every token answers 404; any other probe
# failure is "could not check" and the build goes on with one pipeline.log line.
#
# PINNED (bin/lib/rb/cross-repo-read.sh sourced; the REAL gate block lifted from
# bin/lib/rb/plan.sh by its markers; a stub curl answers per repo and token):
#   1 declared repo, 404 on every token: RESULT PLAN_BLOCKED cross-repo-read
#     <repo>, exit 4, plan.md line 1 is the BLOCKED marker (PLAN_IS_BLOCKED
#     reads it), the plan is kept below, one ALERTS line names the setting.
#   2 200 on GH_EXTRA_READ_TOKEN, 404 on GH_TOKEN: passes.
#   3 the adversarial negatives: none blocks, plan.md unchanged; 403, 429,
#     500 and a timeout each add one pipeline.log line with `unknown`.
#   4 the prompt sentence is in the plan prompt and names CROSS-REPO-READ:.
#   5 no token value reaches pipeline.log, ALERTS or RESULT.
#   6 a REUSED plan.md (pre-plan HIT, resumed build) meets the gate too: the
#     real span from the lib source through the checkpoint to the gate, run
#     on a plan.md already in the build dir, blocks; the pre-plan prompt asks
#     for the declaration line (BH-5910 review B2).
# Run from anywhere: bash tests/plan-cross-repo-read.bh-5910-test.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/rb-all.sh" || exit 1
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh")
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

LIB="$DIR/bin/lib/rb/cross-repo-read.sh"
[ -r "$LIB" ] && ok || { bad "bin/lib/rb/cross-repo-read.sh is missing"; echo "plan-cross-repo-read (BH-5910): $PASS passed, $FAIL failed"; exit 1; }
H="$T/h"
mkdir -p "$H/bin/lib/rb" "$T/fakebin"
scratch_install_closure bin/lib/rb/cross-repo-read.sh "$H" >/dev/null || { echo "closure install failed"; exit 1; }
scratch_install_closure bin/lib/gh-token-live.sh "$H" >/dev/null || { echo "closure install failed"; exit 1; }
cat > "$H/bin/fleet-conf.sh" <<'STUB'
#!/bin/bash
[ "${2:-}" = repo ] && echo example-org/proj-repo
STUB
chmod +x "$H/bin/fleet-conf.sh"

# The curl stub: CURL_RULES holds "<owner/repo> <token|*> <code|timeout>" lines,
# first match wins; anything unmatched is a 404.
cat > "$T/fakebin/curl" <<'SH'
#!/bin/bash
URL=""; TOK=""
while [ $# -gt 0 ]; do
  case "$1" in
    -H) case "$2" in "Authorization: token "*) TOK="${2#Authorization: token }" ;; esac; shift 2 ;;
    -m|-o|-w|-X|-d) shift 2 ;;
    -*) shift ;;
    *) URL="$1"; shift ;;
  esac
done
SLUG="${URL#*/repos/}"
printf '%s %s\n' "$SLUG" "$TOK" >> "$CURL_LOG"
while read -r s t c; do
  [ -n "$s" ] || continue
  [ "${s,,}" = "${SLUG,,}" ] || continue
  [ "$t" = '*' ] || [ "$t" = "$TOK" ] || continue
  [ "$c" = timeout ] && { printf '000'; exit 28; }
  printf '%s' "$c"; exit 0
done <<< "${CURL_RULES:-}"
printf '404'
SH
chmod +x "$T/fakebin/curl"

BLOCK=$(sed -n '/^# >>> cross-repo-read gate (BH-5910)/,/^# <<< cross-repo-read gate/p' "$DIR/bin/lib/rb/plan.sh")
[ -n "$BLOCK" ] && ok || bad "the '# >>> cross-repo-read gate (BH-5910)' block is not in bin/lib/rb/plan.sh"
cat > "$T/gate.sh" <<EOF
set -uo pipefail
HARNESS="$H"; PROJECT=proj; KEY=BH-1; BUILD="\$1"; REPO="$T/norepo"; ALERTS="$T/ALERTS.log"
STAMP() { echo 2026-10-10T00:00:00Z; }
BB() { printf '%s\n' "\$*" >> "$T/bb.calls"; }
RESULT() { printf '%s\n' "\$*" > "$T/result"; }
. "\$HARNESS/bin/lib/gh-token-live.sh"
. "\$HARNESS/bin/lib/rb/cross-repo-read.sh"
f() {
$BLOCK
}
f; echo "FELL_THROUGH"
EOF

PLAN_BODY='# BH-1 — a plan

## Scope
Copy the parser from the sibling repo.
'
# run_gate <plan text> [VAR=value ...] -> GRC (exit code), GOUT (stdout)
run_gate() {
  local text="$1"; shift
  rm -rf "$T/build"; mkdir -p "$T/build"; printf '%s' "$text" > "$T/build/plan.md"
  : > "$T/result"; : > "$T/bb.calls"; : > "$T/ALERTS.log"; : > "$T/curl.log"
  GOUT=$(env -i PATH="$T/fakebin:/usr/bin:/bin" HOME="$T" CURL_LOG="$T/curl.log" GH_APP_API_BASE=http://api.test \
    GH_TOKEN_LIVE_FILE="$T/absent" GH_TOKEN_READ_FILE="$T/absent" GH_TOKEN=tok-fixture-project "$@" \
    bash "$T/gate.sh" "$T/build" 2>"$T/gate.err")
  GRC=$?
}
unchanged() { [ "$(cat "$T/build/plan.md")" = "$(printf '%s' "$1")" ]; }

# ── 1. a declared repo nobody can read: PLAN_BLOCKED ────────────────────────
P1="${PLAN_BODY}
CROSS-REPO-READ: example-org/OtherRepo
"
run_gate "$P1" GH_EXTRA_READ_TOKEN=tok-fixture-read
[ "$GRC" = 4 ] && ok || bad "1: the gate must exit 4, got $GRC ($GOUT / $(cat "$T/gate.err"))"
case "$(cat "$T/result")" in
  "PLAN_BLOCKED cross-repo-read example-org/OtherRepo $T/build/plan.md") ok ;;
  *) bad "1: RESULT must be 'PLAN_BLOCKED cross-repo-read example-org/OtherRepo <plan.md>', got '$(cat "$T/result")'" ;;
esac
head -1 "$T/build/plan.md" | grep -q '^BLOCKED: cross-repo-read example-org/OtherRepo ' && ok || bad "1: plan.md line 1 must be the BLOCKED marker, got: $(head -1 "$T/build/plan.md")"
head -1 "$T/build/plan.md" | grep -q 'lane.fly-pool.proj.extra_read_repos' && ok || bad "1: the marker must name the setting"
# The pipeline's own marker reader stops on it.
PIB=$(sed -n '/^PLAN_IS_BLOCKED() {/,/^}/p' "$RB_ALL")
[ -n "$PIB" ] && bash -c "$PIB"$'\nPLAN_IS_BLOCKED "$1"' _ "$T/build/plan.md" && ok || bad "1: PLAN_IS_BLOCKED (bin/run-build.sh) must read the new plan.md as blocked"
grep -q '^## Scope' "$T/build/plan.md" && grep -q '^CROSS-REPO-READ: example-org/OtherRepo' "$T/build/plan.md" && ok || bad "1: the original plan must stay below the marker"
[ "$(grep -c . "$T/ALERTS.log")" = 1 ] && grep -q 'example-org/OtherRepo' "$T/ALERTS.log" && grep -q 'extra_read_repos' "$T/ALERTS.log" && grep -q 'proj' "$T/ALERTS.log" && ok \
  || bad "1: one ALERTS line naming the repo, the project and extra_read_repos, got: $(cat "$T/ALERTS.log")"
grep -q '^plan_blocked ' "$T/bb.calls" && ok || bad "1: BB plan_blocked must be called, got: $(cat "$T/bb.calls")"
# Both tokens were tried before calling it unreadable.
grep -q 'example-org/OtherRepo tok-fixture-read' "$T/curl.log" && grep -q 'example-org/OtherRepo tok-fixture-project' "$T/curl.log" && ok \
  || bad "1: the probe must try the read token and the project token, got: $(cat "$T/curl.log")"
grep -rq 'tok-fixture' "$T/ALERTS.log" "$T/result" "$T/build/" "$T/gate.err" && bad "5: a token value reached ALERTS, RESULT, plan.md, pipeline.log or stderr" || ok

# A second declared repo: the first unreadable one is named.
run_gate "${PLAN_BODY}
- \`CROSS-REPO-READ: example-org/ReadableRepo\`
* CROSS-REPO-READ: example-org/OtherRepo
" CURL_RULES='example-org/ReadableRepo * 200'
[ "$GRC" = 4 ] && grep -q '^PLAN_BLOCKED cross-repo-read example-org/OtherRepo ' "$T/result" && ok \
  || bad "1b: the bullet/backtick forms are declarations and the unreadable one blocks, rc=$GRC result=$(cat "$T/result")"

# ── 2. readable with the read token only: passes ────────────────────────────
run_gate "$P1" GH_EXTRA_READ_TOKEN=tok-fixture-read CURL_RULES='example-org/OtherRepo tok-fixture-read 200'
[ "$GRC" = 0 ] && grep -q FELL_THROUGH <<<"$GOUT" && [ ! -s "$T/result" ] && ok || bad "2: a repo the read token can read must pass, rc=$GRC result=$(cat "$T/result")"
unchanged "$P1" && ok || bad "2: plan.md must be unchanged"
# The read token from the file the pool pushes, not only from env.
printf 'tok-fixture-file\n' > "$T/readfile"
run_gate "$P1" GH_TOKEN_READ_FILE="$T/readfile" CURL_RULES='example-org/OtherRepo tok-fixture-file 200'
[ "$GRC" = 0 ] && [ ! -s "$T/result" ] && ok || bad "2: the read token file must be tried, rc=$GRC"

# ── 3. adversarial negatives: none may block ────────────────────────────────
neg() { # neg <label> <plan text> [VAR=value ...]
  local label="$1" text="$2"; shift 2
  run_gate "$text" "$@"
  [ "$GRC" = 0 ] && [ ! -s "$T/result" ] && unchanged "$text" && [ ! -s "$T/ALERTS.log" ] && ok \
    || bad "3/$label: must not block (rc=$GRC result=$(cat "$T/result") alerts=$(cat "$T/ALERTS.log"))"
}
neg prose "${PLAN_BODY}We copy the parser from example-org/OtherRepo as reference.
"
neg paths "${PLAN_BODY}Touch bin/lib/rb/plan.sh and docs/notes/x.md.
"
neg url "${PLAN_BODY}See https://github.com/example-org/OtherRepo/blob/main/x.ts for context.
"
neg placeholder "${PLAN_BODY}CROSS-REPO-READ: <owner>/<repo>
"
neg own-slug "${PLAN_BODY}CROSS-REPO-READ: example-org/PROJ-REPO
"
neg midline "${PLAN_BODY}Write one line CROSS-REPO-READ: example-org/OtherRepo per repo.
"
grep -q 'example-org/OtherRepo\|PROJ-REPO' "$T/curl.log" && bad "3: prose, URLs, placeholders and the own slug must not be probed" || ok
for c in 403 429 500 timeout; do
  neg "probe-$c" "$P1" CURL_RULES="example-org/OtherRepo * $c"
  [ "$(grep -c 'cross-repo-read.*unknown' "$T/build/pipeline.log" 2>/dev/null)" = 1 ] && ok \
    || bad "3/probe-$c: one pipeline.log line with cross-repo-read and unknown, got: $(cat "$T/build/pipeline.log" 2>/dev/null)"
done
# A 404 on one token and a 403 on the other is "could not check", never "missing".
neg mixed-404-403 "$P1" GH_EXTRA_READ_TOKEN=tok-fixture-read CURL_RULES='example-org/OtherRepo tok-fixture-read 403'
# No token at all: unknown, never missing.
neg no-token "$P1" GH_TOKEN=
grep -q 'unknown' "$T/build/pipeline.log" 2>/dev/null && ok || bad "3/no-token: must log unknown"
grep -rq 'tok-fixture' "$T/build/" && bad "5: a token value reached pipeline.log" || ok

# ── 4. the prompt sentence ──────────────────────────────────────────────────
NOTE=$(bash -c ". '$LIB' && xrepo_plan_note")
grep -q 'CROSS-REPO-READ: <owner>/<repo>' <<<"$NOTE" && ok || bad "4: xrepo_plan_note must name the declaration line, got: $NOTE"
# TEST-CHANGE (BH-7970): the call moved from the CC plan line to the SP_PLAN_XREPO precompute, and the template carries its token.
PROMPT=$(grep -m1 '^SP_PLAN_XREPO=' "$DIR/bin/lib/rb/plan.sh")
grep -q 'xrepo_plan_note' <<<"$PROMPT" && grep -qF '${SP_PLAN_XREPO}' "$DIR/prompts/stages/plan.md" && ok || bad "4: the plan prompt (CC plan line in bin/lib/rb/plan.sh) must call xrepo_plan_note"
grep -q 'lib/rb/cross-repo-read.sh' "$DIR/bin/lib/rb/plan.sh" && ok || bad "4: bin/lib/rb/plan.sh must source bin/lib/rb/cross-repo-read.sh"

# ── 6. a reused plan (pre-plan HIT, resume) meets the gate ──────────────────
# The REAL span: the lib source above the checkpoint, the checkpoint (its hit
# branch reuses plan.md; the else branch is the planner and never runs here),
# and the gate below it. Lifted by its anchors, not copied.
SPAN=$(sed -n '/^# BH-5910: the cross-repo-read lib/,/^# <<< cross-repo-read gate/p' "$DIR/bin/lib/rb/plan.sh")
grep -q '^fi  # end PLAN checkpoint' <<<"$SPAN" && grep -q 'PLAN checkpoint hit' <<<"$SPAN" && ok \
  || bad "6: the gate must sit below 'fi  # end PLAN checkpoint', with the lib source above the checkpoint"
cat > "$T/span.sh" <<EOF
set -uo pipefail
HARNESS="$H"; PROJECT=proj; KEY=BH-1; BUILD="\$1"; REPO="$T/norepo"; ALERTS="$T/ALERTS.log"
FP_PLAN=""; FP_BEFORE=""
STAMP() { echo 2026-10-10T00:00:00Z; }
BB() { printf '%s\n' "\$*" >> "$T/bb.calls"; }
RESULT() { printf '%s\n' "\$*" > "$T/result"; }
CC() { echo "CC_RAN" >> "$T/cc.calls"; }
$PIB
. "\$HARNESS/bin/lib/gh-token-live.sh"
f() {
$SPAN
}
f; echo "FELL_THROUGH"
EOF
rm -rf "$T/build"; mkdir -p "$T/build"; printf '%s' "$P1" > "$T/build/plan.md"
: > "$T/result"; : > "$T/bb.calls"; : > "$T/ALERTS.log"; : > "$T/curl.log"; rm -f "$T/cc.calls"
GOUT=$(env -i PATH="$T/fakebin:/usr/bin:/bin" HOME="$T" CURL_LOG="$T/curl.log" GH_APP_API_BASE=http://api.test \
  GH_TOKEN_LIVE_FILE="$T/absent" GH_TOKEN_READ_FILE="$T/absent" GH_TOKEN=tok-fixture-project \
  bash "$T/span.sh" "$T/build" 2>"$T/span.err"); GRC=$?
[ ! -e "$T/cc.calls" ] && grep -q 'PLAN checkpoint hit' "$T/build/pipeline.log" 2>/dev/null && ok \
  || bad "6: the span must take the checkpoint-hit branch (reuse), log: $(cat "$T/build/pipeline.log" 2>/dev/null)"
[ "$GRC" = 4 ] && grep -q '^PLAN_BLOCKED cross-repo-read example-org/OtherRepo ' "$T/result" && ok \
  || bad "6: a reused plan that declares an unreadable repo must block, rc=$GRC result=$(cat "$T/result") err=$(cat "$T/span.err")"
head -1 "$T/build/plan.md" | grep -q '^BLOCKED: cross-repo-read example-org/OtherRepo ' && ok || bad "6: the reused plan.md must carry the BLOCKED marker"
# The pre-plan writes the same declaration lines, so a HIT has something to gate.
PPROMPT=$(grep -m1 -A1 'agent-call.sh" preplan ' "$DIR/bin/run-preplan.sh")
grep -q 'xrepo_plan_note' <<<"$PPROMPT" && ok || bad "6: the pre-plan prompt (bin/run-preplan.sh) must call xrepo_plan_note"
grep -q '^\[ -r "\$HARNESS/bin/lib/rb/cross-repo-read.sh" \] && \. ' "$DIR/bin/run-preplan.sh" && ok \
  || bad "6: bin/run-preplan.sh must source bin/lib/rb/cross-repo-read.sh"

echo "plan-cross-repo-read (BH-5910): $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
