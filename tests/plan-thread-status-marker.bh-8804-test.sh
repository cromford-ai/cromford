#!/bin/bash
# tests/plan-thread-status-marker.bh-8804-test.sh — BH-8804: a status comment
# by our own App must not make a running build PLAN_STALE.
#
# 2026-10-30 00:48:58Z our App posted a stop report on #8775 (comment
# 6512133562). The plan-thread gate (bin/lib/plan-thread.sh, ptg_classify)
# counted it as steering, and at 01:40:52Z the pool reaped a build that had run
# since 23:50Z. The fix: a comment by one of our Apps whose first non-blank line
# matches a registered marker in catalog/plan-thread-status-markers.txt is not
# steering. A person is never skipped.
#
# What this suite pins (the plan's acceptance tests):
#   M1  our App, marker on line 1: rc 0, `1 status comment(s) skipped`
#   M2  our App, no marker: rc 1, the refuse line keeps its shape
#   M3  a person with a marker: rc 1
#   M4  a third-party bot with a marker: rc 0, `0 status comment(s) skipped`
#   M5  the catalog: format, valid EREs, every writer carries its marker
#   M6  the #8775 stop report with its marker: rc 0, 1 skipped
#   M7  sg_notice's real body, fed back as our App's comment: rc 0, 1 skipped
#   M8  the negative list (marker not on line 1, unknown lane, partial match,
#       blank line then marker, a person beside a marked comment, a `.*`
#       catalog, no catalog)
# Pure: jq and fixtures, no network, literal timestamps, unique ids per case.
# Run: HARNESS_TEST_SANDBOX=1 bash tests/plan-thread-status-marker.bh-8804-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
SRC=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

H="$T/h"; mkdir -p "$H/bin/lib" "$H/catalog"
scratch_install_closure bin/lib/plan-thread.sh "$H" >/dev/null || bad "cannot install the closure of bin/lib/plan-thread.sh"
scratch_install_closure bin/lib/selection-gate.sh "$H" >/dev/null || bad "cannot install the closure of bin/lib/selection-gate.sh"
CAT="$SRC/catalog/plan-thread-status-markers.txt"
[ -r "$CAT" ] && cp "$CAT" "$H/catalog/" || bad "M5 catalog/plan-thread-status-markers.txt exists"
LIB="$H/bin/lib/plan-thread.sh"
APPS='["cromford-board"]'
STAMP0='2026-10-29T23:50:00Z'
APP='cromford-board[bot]'
PLAN="$T/plan.md"
export TMPDIR="$T/tmp"; mkdir -p "$TMPDIR"
printf '# Plan\n\n## Spec changes from comments\n\nnone\n' > "$PLAN"

# cm <id> <login> <type> <created> <body> — one REST comment
cm() {
  jq -nc --argjson id "$1" --arg l "$2" --arg t "$3" --arg c "$4" --arg b "$5" \
    '{id:$id, node_id:("IC_kwDOfixture" + ($id|tostring)), user:{login:$l,type:$t}, created_at:$c, updated_at:$c, body:$b}'
}
arr() { jq -sc '.'; }
# classify <comments-json> -> $OUT, $RC (PTG_STATUS_MARKERS passes through)
classify() {
  OUT=$(HARNESS="$H" bash -c '. "$1"; ptg_classify "$2" "$3" "$4" "$5"' _ "$LIB" "$PLAN" "$STAMP0" "$1" "$APPS" 2>/dev/null)
  RC=$?
}
NL=$'\n'

# M1 — our App, the selection-gate marker on line 1
classify "$(cm 880401 "$APP" Bot 2026-10-30T00:10:00Z "<!-- harness-status: selection-gate -->${NL}The build is done, but 1 test suite(s) failed." | arr)"
[ "$RC" = 0 ] && [[ "$OUT" == ok$'\t'*", 1 status comment(s) skipped" ]] && ok \
  || bad "M1 our App with a marker is skipped (rc $RC, '$OUT')"

# M2 — our App, no marker: refuse, shape unchanged
classify "$(cm 880402 "$APP" Bot 2026-10-30T00:11:00Z "Please also add a region column." | arr)"
[ "$RC" = 1 ] && [ "$OUT" = $'refuse\t880402 cromford-board[bot] 2026-10-30T00:11:00Z' ] && ok \
  || bad "M2 our App with no marker refuses in today's shape (rc $RC, '$OUT')"

# M3 — a person with a registered marker on line 1
classify "$(cm 880403 operator User 2026-10-30T00:12:00Z "<!-- harness-status: results-sweep -->${NL}Also drop the discount toggle." | arr)"
[ "$RC" = 1 ] && [ "$OUT" = $'refuse\t880403 operator 2026-10-30T00:12:00Z' ] && ok \
  || bad "M3 a person is never skipped (rc $RC, '$OUT')"

# M4 — a third-party bot with a marker: not ours, ignored as today
classify "$(cm 880404 'coderabbitai[bot]' Bot 2026-10-30T00:13:00Z "<!-- harness-status: results-sweep -->${NL}Summary." | arr)"
[ "$RC" = 0 ] && [[ "$OUT" == ok$'\t'"0 newer"*", 0 status comment(s) skipped" ]] && ok \
  || bad "M4 a third-party bot is ignored, 0 skipped (rc $RC, '$OUT')"

# M5 — the catalog
if [ -r "$CAT" ]; then
  lines=0; WRE='^# ([^ ]+) ' 
  while IFS= read -r line; do
    case "$line" in ''|'#'*) continue ;; esac
    lines=$((lines+1))
    ere=${line%%$'\t'*}; rest=${line#*$'\t'}
    [ "$ere" != "$line" ] || { bad "M5 catalog line has no TAB: '$line'"; continue; }
    [[ "$rest" =~ $WRE ]] || { bad "M5 catalog line has no '# <path>': '$line'"; continue; }
    wpath=${BASH_REMATCH[1]}
    [[ "$ere" == '^<!-- '* ]] || bad "M5 ERE does not start '^<!-- ': '$ere'"
    grep -qE -- "$ere" /dev/null 2>/dev/null; [ $? != 2 ] || bad "M5 ERE is invalid: '$ere'"
    [ -f "$SRC/$wpath" ] || { bad "M5 writer $wpath does not exist"; continue; }
    lit=${ere#^}; lit=${lit%\$}
    grep -qE -- "$lit" "$SRC/$wpath" && ok || bad "M5 writer $wpath does not carry its marker '$lit'"
  done < "$CAT"
  [ "$lines" -ge 3 ] && ok || bad "M5 catalog registers the three writers (got $lines lines)"
  # every rendered GitHub-board prompt that carries the template's SOP line carries the sweep marker
  for p in "$SRC"/prompts/*.md; do
    grep -q 'Built work = PR link' "$p" || continue
    grep -qF '<!-- harness-status: results-sweep -->' "$p" && ok || bad "M5 ${p#"$SRC"/} lacks the results-sweep marker"
  done
fi

# M6 — the #8775 stop report. The full body of comment 6512133562 was not
# readable from this box; the fixture is the text the ticket quotes, in the
# results sweep's GATE_RED shape, with its marker added.
M6BODY="<!-- harness-status: results-sweep -->
Two builds of this hotfix stopped before a PR opened. The full merge-queue selection was red on our test host each time:

- \`tests/plan-thread-gate.bh-5799-test.sh\`

We did not relaunch it. No PR was opened."
classify "$(cm 6512133562 "$APP" Bot 2026-10-30T00:48:58Z "$M6BODY" | arr)"
[ "$RC" = 0 ] && [[ "$OUT" == *", 1 status comment(s) skipped" ]] && ok \
  || bad "M6 the #8775 stop report with its marker is skipped (rc $RC, '$OUT')"

# M7 — sg_notice's real body, round-tripped through the classifier
SB="$T/sg"; mkdir -p "$SB/build"
printf 'head: x\nbase: x\nsuites: 5\nrc: 1\nred: tests/a.sh,tests/b.sh\nnoted: -\n' > "$SB/build/gate.txt"
cat > "$H/bin/fleet-conf.sh" <<'EOF'
#!/bin/bash
case "$2" in board_prefix) echo - ;; repo) echo example-org/cromford ;; *) echo - ;; esac
EOF
chmod +x "$H/bin/fleet-conf.sh"
HARNESS="$H" BUILD="$SB/build" PROJECT=cromford KEY=BH-8804 TICKET=8804 BUILDER_DIRECT_ON=1 SBODY="$SB/body" bash -c '
  . "$1"
  STAMP() { echo 2026-10-30T00:00:00Z; }
  gh_rest_comment() { cp "$3" "$SBODY"; }
  sg_notice' _ "$H/bin/lib/selection-gate.sh" >/dev/null 2>&1
[ "$(head -n 1 "$SB/body" 2>/dev/null)" = '<!-- harness-status: selection-gate -->' ] && ok \
  || bad "M7 sg_notice's body starts with its marker (line 1 '$(head -n 1 "$SB/body" 2>/dev/null)')"
classify "$(cm 880407 "$APP" Bot 2026-10-30T00:14:00Z "$(cat "$SB/body" 2>/dev/null)" | arr)"
[ "$RC" = 0 ] && [[ "$OUT" == *", 1 status comment(s) skipped" ]] && ok \
  || bad "M7 sg_notice's posted body is skipped as our App's comment (rc $RC, '$OUT')"

# M8 — the negative list
classify "$(cm 880481 "$APP" Bot 2026-10-30T00:15:00Z "Status quoted below.${NL}<!-- harness-status: results-sweep -->" | arr)"
[ "$RC" = 1 ] && [[ "$OUT" == $'refuse\t880481 '* ]] && ok || bad "M8 marker on the last line refuses (rc $RC, '$OUT')"
classify "$(cm 880482 "$APP" Bot 2026-10-30T00:16:00Z "<!-- harness-status: unknown-lane -->${NL}text" | arr)"
[ "$RC" = 1 ] && [[ "$OUT" == $'refuse\t880482 '* ]] && ok || bad "M8 an unregistered lane marker refuses (rc $RC, '$OUT')"
classify "$(cm 880483 "$APP" Bot 2026-10-30T00:17:00Z "<!-- harness-status: results-sweep --> HOLD${NL}text" | arr)"
[ "$RC" = 1 ] && [[ "$OUT" == $'refuse\t880483 '* ]] && ok || bad "M8 a partial line-1 match refuses (rc $RC, '$OUT')"
classify "$(cm 880484 "$APP" Bot 2026-10-30T00:18:00Z "${NL}  ${NL}<!-- harness-status: board-closeout -->${NL}Built and opened for review." | arr)"
[ "$RC" = 0 ] && [[ "$OUT" == *", 1 status comment(s) skipped" ]] && ok || bad "M8 blank lines then the marker is skipped (rc $RC, '$OUT')"
classify "$( { cm 880485 "$APP" Bot 2026-10-30T00:19:00Z "<!-- harness-status: results-sweep -->${NL}x"; cm 880486 operator User 2026-10-30T00:20:00Z "change the scope"; } | arr)"
[ "$RC" = 1 ] && [ "$OUT" = $'refuse\t880486 operator 2026-10-30T00:20:00Z' ] && ok \
  || bad "M8 a person beside a marked App comment still refuses, naming only the person (rc $RC, '$OUT')"
printf '.*\t# anything — must be dropped\n' > "$T/all.txt"
OUT=$(PTG_STATUS_MARKERS="$T/all.txt" HARNESS="$H" bash -c '. "$1"; ptg_classify "$2" "$3" "$4" "$5"' _ "$LIB" "$PLAN" "$STAMP0" \
  "$(cm 880487 "$APP" Bot 2026-10-30T00:21:00Z "<!-- harness-status: results-sweep -->${NL}x" | arr)" "$APPS" 2>/dev/null); RC=$?
[ "$RC" = 1 ] && ok || bad "M8 a '.*' catalog line never exempts (rc $RC, '$OUT')"
OUT=$(PTG_STATUS_MARKERS="$T/none.txt" HARNESS="$H" bash -c '. "$1"; ptg_classify "$2" "$3" "$4" "$5"' _ "$LIB" "$PLAN" "$STAMP0" \
  "$(cm 880488 "$APP" Bot 2026-10-30T00:22:00Z "<!-- harness-status: results-sweep -->${NL}x" | arr)" "$APPS" 2>/dev/null); RC=$?
[ "$RC" = 1 ] && ok || bad "M8 no catalog file means no skip (rc $RC, '$OUT')"
# no temp files left behind
left=$(find "$TMPDIR" -maxdepth 1 -name 'ptg-*' 2>/dev/null | wc -l)
[ "$left" = 0 ] && ok || bad "M8 the classifier's temp files are removed ($left left)"

echo "plan-thread-status-marker (BH-8804): $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
