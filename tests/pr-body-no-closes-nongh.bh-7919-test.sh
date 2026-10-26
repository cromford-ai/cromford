#!/bin/bash
# tests/pr-body-no-closes-nongh.bh-7919-test.sh — BH-7919: a PR body never
# says `Closes #N` or `Refs #N` for a ticket that is not a GitHub issue. A
# Linear project registered with fleet.conf column 4 `-` used to get
# `Closes #12` for CRO-12, and a merge would close GitHub issue #12.
#
#   N1  linear project (row linear, column 4 `-`): no `Closes #` / `Refs #` line
#   N2  the same with a REFUTED claim in evidence.json: still none, and no
#       "Acceptance self-check" section (that section rides the Refs line)
#   N3  CLOSE_ISSUE_AFTER_MERGE on that project sends 0 gh calls
#   N4  github-issues project: line 2 is `Closes #269`, and the close-out runs
#   N5  the GitHub body with no row equals the body with a github-issues row
#
# The evidence block and the merge-note functions are extracted VERBATIM from
# the shipped pipeline (tests/lib/rb-all.sh) by their markers, as
# tests/pr-body-closes-test.sh does. The settings worker is a stub
# bin/jobs-client.sh; gh is a stub that logs. No network.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/rb-all.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "jq missing — skipping"; exit 0; }

H="$T/h"; ROWS="$T/rows"
export FLEET_CONF="$H/fleet.conf"  # fleet-conf.sh reads /root/harness/fleet.conf before its own dir
mkdir -p "$H/bin/lib" "$H/env" "$ROWS" "$T/build" "$T/fakebin" "$T/repo"
cat > "$H/bin/jobs-client.sh" <<'SH'
# stub jobs client: setting_get <key> -> $ROWS/<key>; rc 2 no row
setting_get() { [ -r "$ROWS/$1" ] || return 2; cat "$ROWS/$1"; }
SH
scratch_install_closure bin/fleet-conf.sh "$H" >/dev/null || exit 1
scratch_install_closure bin/lib/tracker.sh "$H" >/dev/null || exit 1
scratch_install_closure bin/lib/gh-rest.sh "$H" >/dev/null || exit 1
cat > "$H/fleet.conf" <<'CONF'
# <project> <repo> <prod> <board-api-prefix> <offset> [box] [ip]
ts  o/r   https://ts.example  -  1 box-1 192.0.2.1
ln  o/ln  https://ln.example  -  6 box-1 192.0.2.1
CONF
printf 'linear' > "$ROWS/tracker_adapter.ln"
printf 'LINEAR_API_KEY=tok-fixture-ln\nLINEAR_TEAM=CRO\n' > "$H/env/ln.env"

RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh")
awk '/^# >>> evidence block/{f=1;next} /^# <<< evidence block/{exit} f' "$RB_ALL" > "$T/block.sh"
[ -s "$T/block.sh" ] && grep -q CLOSES_LINE "$T/block.sh" && ok || bad "could not extract the evidence block with CLOSES_LINE — markers moved?"
awk '/^# >>> merge note fn/{f=1;next} /^# <<< merge note fn/{exit} f' "$RB_ALL" > "$T/mergenote.sh"
[ -s "$T/mergenote.sh" ] && ok || bad "could not extract the merge note functions"
( cd "$T/repo" && git init -q -b main && git config user.email t@example.com && git config user.name t \
  && echo one > a.txt && git add -A && git -c commit.gpgsign=false commit -qm "CRO-12: the subject" ) >/dev/null 2>&1
cat > "$T/fakebin/gh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$GH_SINK"
case "$*" in
  *"-X POST"*comments*) printf 'HTTP/2.0 201 Created\nx-stub: 1\n\n{"id":1}\n' ;;
  *) printf 'HTTP/2.0 200 OK\nx-stub: 1\n\n{"state":"closed"}\n' ;;
esac
exit 0
SH
chmod +x "$T/fakebin/gh"
printf '#!/bin/bash\nprintf "## Evidence\\n\\n| check | result |\\n|---|---|\\n| suite | HARNESS_EXIT: 0 |\\n"\n' > "$H/bin/evidence-summary.sh"
chmod +x "$H/bin/evidence-summary.sh"
ev_refuted() {
  jq -nc '{total:2,confirmed:1,refuted:1,inconclusive:0,claims:[
    {n:1,claim:"tests/a-test.sh passes",verdict:"CONFIRMED",artifact:"harness-suite.txt:3",note:"",proposed:"CONFIRMED"},
    {n:2,claim:"the prod seed writes 3 rows",verdict:"REFUTED",artifact:"validate.txt:9",note:"0 rows",proposed:"REFUTED"}]}' > "$T/build/evidence.json"
}

drive() { # drive <project> <key> <bodyfile>
  local project="$1" key="$2" out="$3"
  : > "$T/gh.txt"; : > "$T/build/pipeline.log"; : > "$out"
  ( cd "$T/repo" || exit 1
    env PATH="$T/fakebin:$PATH" HARNESS="$H" ROWS="$ROWS" BUILD="$T/build" GH_SINK="$T/gh.txt" \
      PROJECT="$project" KEY="$key" \
    bash -c '
      set -uo pipefail
      STAMP() { echo TS; }
      SLUG=o/r; BASE=main; TIER=1; QA_NOTE=""; MIG_NOTE=""; ADDED_SQL=""; E2E_VERDICT=pass
      CHANGED="a.txt"; TAMPER_RC=0; REPRO_RC=0; INTENT_RC=0
      WHAT_LIST="- did a thing"; WHY_EXCERPT="because"; VERIFY_LINE="v"; SPEC_LINE="s"
      PLAN_MODEL=pm; EXECUTE_MODEL=em; REVIEW_MODEL=rm; MIG_SECTION=""; COST_LINE="c"
      CTX_SIG=sig; CTX_COMMIT=abc; CTX_SYNC=yes; CTX_FRESH=yes
      job_evidence_put() { return 0; }
      . "$HARNESS/bin/lib/gh-rest.sh"
      . "$0"; . "$1"
      printf "%s" "$(PR_BODY_FOR "$EVIDENCE_SECTION")" > "$2"
      CLOSE_ISSUE_AFTER_MERGE https://github.com/o/r/pull/7
    ' "$T/mergenote.sh" "$T/block.sh" "$out" 2>"$T/err.txt" )
}

# N1 — linear, column 4 `-`
rm -f "$T/build/evidence.json"
drive ln CRO-12 "$T/n1.txt"
grep -q '## What' "$T/n1.txt" && ok || bad "N1 the body did not render: $(head -3 "$T/n1.txt") err=$(cat "$T/err.txt")"
grep -qE '^(Closes|Refs) #' "$T/n1.txt" && bad "N1 a linear PR body names a GitHub issue: $(grep -E '^(Closes|Refs) #' "$T/n1.txt")" || ok
# N3 — and the close-out after a merge calls nothing
[ -s "$T/gh.txt" ] && bad "N3 CLOSE_ISSUE_AFTER_MERGE on a linear project called gh: $(cat "$T/gh.txt")" || ok

# N2 — the same with a REFUTED claim: the partial-build block must not invent a Refs line
ev_refuted
drive ln CRO-12 "$T/n2.txt"
grep -q '## What' "$T/n2.txt" && ok || bad "N2 the body did not render: err=$(cat "$T/err.txt")"
grep -qE '^(Closes|Refs) #' "$T/n2.txt" && bad "N2 a REFUTED linear build names a GitHub issue: $(grep -E '^(Closes|Refs) #' "$T/n2.txt")" || ok
grep -q 'Acceptance self-check' "$T/n2.txt" && bad "N2 the Refs-only self-check section rendered with no Refs line" || ok
[ -s "$T/gh.txt" ] && bad "N2 a REFUTED linear build called gh: $(cat "$T/gh.txt")" || ok
rm -f "$T/build/evidence.json"

# N4 — github-issues, no row: Closes #269 on line 2, and the close-out runs
drive ts TK-269 "$T/n4.txt"
[ "$(sed -n 2p "$T/n4.txt")" = "Closes #269" ] && ok || bad "N4 line 2 is not 'Closes #269': $(head -3 "$T/n4.txt") err=$(cat "$T/err.txt")"
grep -q -- "-X PATCH repos/o/r/issues/269" "$T/gh.txt" && ok || bad "N4 the close-out did not close issue 269: $(cat "$T/gh.txt")"

# N5 — an explicit github-issues row changes nothing
printf 'github-issues' > "$ROWS/tracker_adapter.ts"
drive ts TK-269 "$T/n5.txt"
rm -f "$ROWS/tracker_adapter.ts"
cmp -s "$T/n4.txt" "$T/n5.txt" && ok || bad "N5 the body with a github-issues row differs from the body with none: $(diff "$T/n4.txt" "$T/n5.txt" | head -5)"

echo "pr-body-no-closes-nongh.bh-7919: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
