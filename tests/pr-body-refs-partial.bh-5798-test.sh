#!/bin/bash
# tests/pr-body-refs-partial.bh-5798-test.sh — BH-5798: a partial build says
# Refs, not Closes, and its evidence names the head it ran on.
#
# WHY. 11 review BLOCKs found "Closes #N" on a PR that left acceptance items
# unmet (a merge would close the ticket and drop the rest), and 15 found a body
# about an older head. bin/run-build.sh's PR body now reads the scored evidence
# ($BUILD/evidence.json, bin/lib/evidence.sh):
#
#   R1  a REFUTED claim: line 2 is "Refs #269", the body lists the claim under
#       "## Acceptance self-check", and no close is attempted after a merge
#   R2  every claim CONFIRMED (or INCONCLUSIVE): "Closes #269", as before
#   R3  the Evidence section carries <!-- evidence-head: <HEAD sha> -->
#   R4  bin/pr-self-check.sh passes R1's body on closes-not-met (Refs) and
#       refuses the same body with Closes put back
#
# The rig is tests/pr-body-closes-test.sh's: the evidence block extracted
# verbatim by its markers and driven with its variable set.
# Run from anywhere: tests/pr-body-refs-partial.bh-5798-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/rb-all.sh" || exit 1
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh")
mkdir -p "$T/bin/lib" "$T/build" "$T/fakebin" "$T/repo"
# (BH-781) CLOSE_ISSUE_AFTER_MERGE's fallback pair writes through
# bin/lib/gh-rest.sh, which bin/run-build.sh sources at the top.
scratch_install_closure bin/lib/gh-rest.sh "$T" >/dev/null || { echo "FAIL: closure of bin/lib/gh-rest.sh"; exit 1; }
# BH-7919: the Closes line (bin/lib/rb/pr.sh) now asks bin/lib/tracker.sh trk_gh_issue_number.
scratch_install_closure bin/lib/tracker.sh "$T" >/dev/null || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

awk '/^# >>> evidence block/{f=1;next} /^# <<< evidence block/{exit} f' "$RB_ALL" > "$T/block.sh"
[ -s "$T/block.sh" ] && grep -q CLOSES_LINE "$T/block.sh" && ok || bad "could not extract the evidence block with CLOSES_LINE — markers moved?"
awk '/^# >>> merge note fn/{f=1;next} /^# <<< merge note fn/{exit} f' "$RB_ALL" > "$T/mergenote.sh"
( cd "$T/repo" && git init -q -b main && git config user.email t@example.com && git config user.name t \
  && echo one > a.txt && git add -A && git -c commit.gpgsign=false commit -qm "TK-269: the subject" ) >/dev/null 2>&1
cat > "$T/bin/fleet-conf.sh" <<'SH'
#!/bin/bash
[ "${2:-}" = board_prefix ] && cat "$T/prefix"
SH
chmod +x "$T/bin/fleet-conf.sh"
# The stub answers in the wire shape bin/lib/gh-rest.sh reads: a status line, a
# blank line, then the body. The PATCH is followed by a VERIFYING RE-READ, so
# the GET has to agree the issue is closed or gh_rest_close returns 75.
cat > "$T/fakebin/gh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$GH_SINK"
if [ "${GH_RC:-0}" != 0 ]; then
  printf 'HTTP/2.0 403 Forbidden\nx-stub: 1\n\n{"message":"refused"}\n'; exit "${GH_RC:-0}"
fi
case "$*" in
  *"-X POST"*comments*) printf 'HTTP/2.0 201 Created\nx-stub: 1\n\n{"id":1}\n' ;;
  *"-X PATCH"*)         printf 'HTTP/2.0 200 OK\nx-stub: 1\n\n{"state":"closed"}\n' ;;
  *"-X GET"*)           printf 'HTTP/2.0 200 OK\nx-stub: 1\n\n{"state":"closed"}\n' ;;
esac
exit 0
SH
chmod +x "$T/fakebin/gh"

drive() { # drive <prefix> <key> [env...]
  local prefix="$1" key="$2"; shift 2
  echo "$prefix" > "$T/prefix"; : > "$T/gh.txt"; : > "$T/build/pipeline.log"; : > "$T/body.txt"
  ( cd "$T/repo" || exit 1
    env PATH="$T/fakebin:$PATH" HARNESS="$T" T="$T" BUILD="$T/build" GH_SINK="$T/gh.txt" KEY="$key" "$@" \
    bash -c '
      set -uo pipefail
      STAMP() { echo TS; }
      PROJECT=ts; SLUG=o/r; BASE=main; TIER=1; QA_NOTE=""; MIG_NOTE=""; ADDED_SQL=""; E2E_VERDICT=pass
      CHANGED="a.txt"; TAMPER_RC=0; REPRO_RC=0; INTENT_RC=0
      WHAT_LIST="- did a thing"; WHY_EXCERPT="because"; VERIFY_LINE="v"; SPEC_LINE="s"
      PLAN_MODEL=pm; EXECUTE_MODEL=em; REVIEW_MODEL=rm; MIG_SECTION=""; COST_LINE="c"
      CTX_SIG=sig; CTX_COMMIT=abc; CTX_SYNC=yes; CTX_FRESH=yes
      job_evidence_put() { return 0; }
      . "$HARNESS/bin/lib/gh-rest.sh"
      . "$0"; . "$1"
      printf "%s" "$(PR_BODY_FOR "$EVIDENCE_SECTION")" > "$2"
      CLOSE_ISSUE_AFTER_MERGE https://github.com/o/r/pull/7
    ' "$T/mergenote.sh" "$T/block.sh" "$T/body.txt" 2>"$T/err.txt" )
}


# The evidence digest the block renders (stubbed: its own suite owns its text).
printf '#!/bin/bash\nprintf "## Evidence\\n\\n| check | result |\\n|---|---|\\n| suite | HARNESS_EXIT: 0 |\\n"\n' > "$T/bin/evidence-summary.sh"
chmod +x "$T/bin/evidence-summary.sh"
HEADSHA=$(git -C "$T/repo" rev-parse HEAD)
ev() { # ev <verdict of claim 2>
  jq -nc --arg v "$1" '{total:2,confirmed:1,refuted:0,inconclusive:0,claims:[
    {n:1,claim:"tests/a-test.sh passes",verdict:"CONFIRMED",artifact:"harness-suite.txt:3",note:"",proposed:"CONFIRMED"},
    {n:2,claim:"the prod seed writes 3 rows",verdict:$v,artifact:"validate.txt:9",note:"0 rows",proposed:$v}]}' > "$T/build/evidence.json"
}

# R1 — a REFUTED claim
ev REFUTED; drive "-" TK-269
[ "$(sed -n 2p "$T/body.txt")" = "Refs #269" ] && ok || bad "R1: a partial build must say Refs on line 2: $(head -3 "$T/body.txt") err=$(cat "$T/err.txt")"
grep -q "Closes #269" "$T/body.txt" && bad "R1: a partial build must not say Closes" || ok
grep -q "^## Acceptance self-check" "$T/body.txt" && grep -q "claim 2: the prod seed writes 3 rows (not met: REFUTED, 0 rows)" "$T/body.txt" \
  && ok || bad "R1: the body must list the claim not met: $(grep -A4 'self-check' "$T/body.txt")"
grep -q -- "-X PATCH repos/o/r/issues/269" "$T/gh.txt" && bad "R1: a partial build must not close the issue after merge" || ok
cp "$T/body.txt" "$T/body-r1.txt"

# R2 — all met
ev CONFIRMED; drive "-" TK-269
[ "$(sed -n 2p "$T/body.txt")" = "Closes #269" ] && ok || bad "R2: a complete build keeps Closes: $(head -3 "$T/body.txt")"
grep -q "^## Acceptance self-check" "$T/body.txt" && bad "R2: no not-met section on a complete build" || ok
ev INCONCLUSIVE; drive "-" TK-269
[ "$(sed -n 2p "$T/body.txt")" = "Closes #269" ] && ok || bad "R2: INCONCLUSIVE is not REFUTED and keeps Closes: $(head -3 "$T/body.txt")"

# R3 — the evidence names the head
grep -qx "<!-- evidence-head: $HEADSHA -->" "$T/body.txt" && ok || bad "R3: the Evidence section must carry the head sha: $(grep -n evidence "$T/body.txt")"

# R4 — the self-check agrees with the body it rendered
H="$T/psc"; mkdir -p "$H"
scratch_install_closure bin/pr-self-check.sh "$H" >/dev/null || bad "R4: closure of bin/pr-self-check.sh"
printf 'closes-not-met\trefuse\t-\tx\n' > "$T/psc.tsv"
PR_SELF_CHECK_CATALOG="$T/psc.tsv" bash "$H/bin/pr-self-check.sh" check --repo "$T/repo" --base HEAD --head HEAD --body "$T/body-r1.txt" >/dev/null 2>&1 \
  && ok || bad "R4: the Refs body must pass closes-not-met"
sed 's/^Refs #269$/Closes #269/' "$T/body-r1.txt" > "$T/body-r1c.txt"
PR_SELF_CHECK_CATALOG="$T/psc.tsv" bash "$H/bin/pr-self-check.sh" check --repo "$T/repo" --base HEAD --head HEAD --body "$T/body-r1c.txt" >/dev/null 2>&1
[ $? = 1 ] && ok || bad "R4: the same body with Closes must be refused"

echo "pr-body-refs-partial.bh-5798: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
