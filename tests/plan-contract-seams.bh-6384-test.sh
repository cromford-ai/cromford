#!/bin/bash
# tests/plan-contract-seams.bh-6384-test.sh — BH-6384: one seam file per
# sibling, `Owns:` lines in each filed child body, the owns-overlap lint, the
# HUB_MODULE signal and the overlap report.
#
# WHY. On project-6-os, 2026-10-12/13, six sibling PRs of split parents were
# lost in about three hours: siblings filed as one parallel wave each edited
# the same existing file, and nothing said so until the merges conflicted.
#
# Every case drives a real entry point: bin/run-decompose.sh (dry run, the real
# filer), bin/decompose-lint.sh, bin/hub-module-warn.sh, bin/preplan-tick.sh,
# bin/planned-files.sh and bin/decompose-overlap-report.sh. No network, no
# model call: agent-call.sh, curl, gh and the jobs client are stubs.
# Run from anywhere: tests/plan-contract-seams.bh-6384-test.sh  (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
export GH_CLI_REST_ADAPTER="$DIR/tests/lib/gh-cli-rest-adapter.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "jq missing — skipping"; exit 0; }

DEC="$DIR/bin/run-decompose.sh"
LINT="$DIR/bin/decompose-lint.sh"
HMW="$DIR/bin/hub-module-warn.sh"
REP="$DIR/bin/decompose-overlap-report.sh"
for s in "$DEC" "$LINT" "$HMW" "$REP"; do [ -x "$s" ] && ok || bad "$s is missing or not executable"; done

# ---- the issues-lane scratch harness (as tests/decompose-contract-first-test.sh)
H="$T/h"
mkdir -p "$H/bin/lib" "$H/logs" "$H/env" "$H/prompts"
. "$DIR/tests/lib/model-route-stub.sh" || exit 1; model_routes_fixture "$H" scoutish || exit 1
cp "$DIR/bin/fleet-conf.sh" "$H/bin/"
cp "$DIR/bin/planned-files.sh" "$H/bin/"
cat > "$H/fleet.conf" <<'CONF'
# <project> <repo> <prod> <board-api-prefix> <offset> [box] [ip]
scoutish      example-org/scoutish   https://scoutish.example  -           9 box-1 192.0.2.9
CONF
# The stub writes the prompt it was handed ($6) so A1 can read it.
printf '#!/bin/bash\necho "AGENT CALL: $*" >> "$AGENT_LOG"\nprintf "%%s" "$6" > "$AGENT_PROMPT"\nexit 0\n' > "$H/bin/agent-call.sh"
chmod +x "$H/bin/agent-call.sh"

drive() { # drive <spec-json or ""> — prints the run's output, exits with its rc
  rm -rf "$T/b"; mkdir -p "$T/b"
  [ -n "$1" ] && printf '%s\n' "$1" > "$T/b/children.json"
  printf 'SIZE_DECLARED: files=18 lines=1900\nSIZE_OVER: lines=1900>300\nSIZE_VERDICT: over\n' > "$T/b/size-gate.txt"
  : > "$T/agent.log"; : > "$T/prompt.txt"
  env HARNESS="$H" FLEET_CONF="$H/fleet.conf" AGENT_LOG="$T/agent.log" AGENT_PROMPT="$T/prompt.txt" \
      DECOMPOSE_DRY_RUN=1 "$DEC" scoutish 552 TK-552 "$T/b" 300 12 2>&1
}

# ===========================================================================
# A1. the decompose prompt asks for one seam file per later child and `owns`
# ===========================================================================
drive "" >/dev/null
[ -s "$T/agent.log" ] && ok || bad "A1 with no children.json the model must be asked"
P1=$(cat "$T/prompt.txt")
grep -qF 'ONE SEAM FILE PER LATER CHILD' <<<"$P1" && ok || bad "A1 prompt lacks 'ONE SEAM FILE PER LATER CHILD'"
grep -qF 'owns —' <<<"$P1" && ok || bad "A1 prompt lacks the 'owns —' spec field"
grep -qF "'Owns:'" <<<"$P1" && ok || bad "A1 prompt does not name the 'Owns:' line"
grep -qF '"owns": [' <<<"$P1" && ok || bad "A1 the prompt's example objects carry no owns array"
grep -qF 'same file <path>' <<<"$P1" && ok || bad "A1 prompt does not name the hard 'same file' fallback"
# The existing seam paragraph is untouched.
grep -qF 'SHARED SEAMS GO IN THE CONTRACT.' <<<"$P1" && ok || bad "A1 the BH-4988 seam paragraph is gone"

# ===========================================================================
# A1b. the filer writes `Owns:` from the spec's owns field
# ===========================================================================
OBS='\n\n## Observable outcome\nThe slice acceptance test passes end to end.'
SPEC_OWNS='[
 {"title":"review bodies contract","contract":"src/review-bodies/index.ts: EXTRA_BODIES; src/review-bodies/autonomy.ts: seam for TK-552.1","after":[],"body":"Seams.'"$OBS"'"},
 {"title":"autonomy body","owns":["src/review-bodies/autonomy.ts"],"after":[],"body":"Fill the seam.'"$OBS"'"},
 {"title":"digest body","owns":["src/review-bodies/digest.ts","  ",7],"after":[],"body":"Fill the other seam.'"$OBS"'"}
]'
OUT=$(drive "$SPEC_OWNS"); RC=$?
[ "$RC" -eq 0 ] && ok || bad "A1b a spec with owns must file (rc=$RC): $OUT"
C1="$T/b/children/child-1.md"; C2="$T/b/children/child-2.md"; C3="$T/b/children/child-3.md"
[ "$(grep -c '^Owns:' "$C2")" -eq 1 ] && ok || bad "A1b child 2 carries exactly one Owns: line: $(cat "$C2")"
grep -qx 'Owns: src/review-bodies/autonomy.ts' "$C2" && ok || bad "A1b child 2 Owns: line: $(cat "$C2")"
grep -qx 'Owns: src/review-bodies/digest.ts' "$C3" && ok || bad "A1b blanks and non-strings are dropped from owns: $(cat "$C3")"
grep -q '^Owns:' "$C1" && bad "A1b the contract has no owns, so no Owns: line: $(cat "$C1")" || ok
grep -q 'child 1 declares no owns' "$T/b/pipeline.log" && ok || bad "A1b a child with no owns is logged: $(cat "$T/b/pipeline.log")"
# The Owns: line comes after the footer, so every footer reader is unchanged.
awk '/^---$/{f=1} f && /^Owns:/{o=1} END{exit !o}' "$C2" && ok || bad "A1b Owns: sits after the footer: $(cat "$C2")"
# The real lint ran on the bodies: two disjoint siblings and an unjudged contract.
grep -q 'DECOMPOSE_LINT no-owns TK-553' "$T/b/pipeline.log" && ok || bad "A1b the lint result is in pipeline.log: $(cat "$T/b/pipeline.log")"
grep -q 'DECOMPOSE_LINT owns-overlap' "$T/b/pipeline.log" && bad "A1b disjoint owns must not warn: $(cat "$T/b/pipeline.log")" || ok

# ===========================================================================
# A3-wired. an overlapping spec puts the warning into pipeline.log
# ===========================================================================
SPEC_OV='[
 {"title":"board contract","contract":"src/board/index.ts: Board","owns":["src/board/index.ts"],"after":[],"body":"Seams.'"$OBS"'"},
 {"title":"board filters","owns":["src/board.tsx","src/board/filters.ts"],"after":[],"body":"Filters.'"$OBS"'"},
 {"title":"board sort","owns":["src/board.tsx"],"after":[],"body":"Sort.'"$OBS"'"},
 {"title":"board export","owns":["src/board.tsx"],"after":["3: same file src/board.tsx"],"body":"Export.'"$OBS"'"}
]'
OUT=$(drive "$SPEC_OV"); RC=$?
[ "$RC" -eq 0 ] && ok || bad "A3-wired an overlapping spec still files: the lint is a warning (rc=$RC): $OUT"
grep -q 'DECOMPOSE_LINT owns-overlap src/board.tsx TK-554 TK-555$' "$T/b/pipeline.log" \
  && ok || bad "A3-wired the unlinked pair 2/3 is warned: $(grep DECOMPOSE_LINT "$T/b/pipeline.log")"
grep -q 'DECOMPOSE_LINT owns-overlap src/board.tsx TK-555 TK-556' "$T/b/pipeline.log" \
  && bad "A3-wired the 'same file' after entry is a hard link and silences 3/4" || ok
grep -q 'DECOMPOSE_LINT owns-overlap src/board.tsx TK-554 TK-556' "$T/b/pipeline.log" \
  && ok || bad "A3-wired 2/4 has no link and is warned: $(grep DECOMPOSE_LINT "$T/b/pipeline.log")"
grep -q 'DECOMPOSE_LINT owns-overlap src/board/index.ts' "$T/b/pipeline.log" \
  && bad "A3-wired the contract's own paths are linked by every sibling's hard DEPENDS" || ok
grep -qE '^DEPENDS: #555 hard — same file src/board.tsx$' "$T/b/children/child-4.md" \
  && ok || bad "A3-wired the fallback is written as a hard DEPENDS: $(cat "$T/b/children/child-4.md")"

# ===========================================================================
# A3. the lint itself
# ===========================================================================
L="$T/lint"; mkdir -p "$L"
body() { printf 'Body.\n\n---\nPart of #100\n%s\n' "$2" > "$L/$1.md"; }
body a 'Owns: src/board.tsx'
body b $'DEPENDS: #101 soft — a separate slice\nOwns: src/board.tsx'
OUT=$("$LINT" 101="$L/a.md" 102="$L/b.md"); RC=$?
[ "$RC" -eq 0 ] && ok || bad "A3 the lint is a warning, rc 0 (rc=$RC)"
[ "$OUT" = 'DECOMPOSE_LINT owns-overlap src/board.tsx 101 102' ] && ok || bad "A3 soft DEPENDS still warns, naming both: '$OUT'"
body c $'DEPENDS: #101 hard — same file src/board.tsx\nOwns: src/board.tsx'
OUT=$("$LINT" 101="$L/a.md" 102="$L/c.md")
[ "$OUT" = 'DECOMPOSE_LINT ok 2 children' ] && ok || bad "A3-neg-1 a hard DEPENDS on A silences it: '$OUT'"
OUT=$("$LINT" TK-101="$L/a.md" TK-102="$L/c.md")
[ "$OUT" = 'DECOMPOSE_LINT ok 2 children' ] && ok || bad "A3-neg-1 a key id links by its numeric suffix: '$OUT'"
body c14 $'DEPENDS: #14 hard — same file src/board.tsx\nOwns: src/board.tsx'
OUT=$("$LINT" 142="$L/a.md" 143="$L/c14.md")
[ "$OUT" = 'DECOMPOSE_LINT owns-overlap src/board.tsx 142 143' ] && ok || bad "A3 '#14' must not link id 142: '$OUT'"
body x1 'Owns: src/x.ts'; body x2 'Owns: src/x.tsx'
OUT=$("$LINT" 1="$L/x1.md" 2="$L/x2.md")
[ "$OUT" = 'DECOMPOSE_LINT ok 2 children' ] && ok || bad "A3-neg-3 src/x.ts vs src/x.tsx is not an overlap: '$OUT'"
body d1 'Owns: src/x/'; body d2 'Owns: lib/y.ts, src/x/a.ts'
OUT=$("$LINT" 1="$L/d1.md" 2="$L/d2.md")
[ "$OUT" = 'DECOMPOSE_LINT owns-overlap src/x/a.ts 1 2' ] && ok || bad "A3-dir src/x/ holds src/x/a.ts: '$OUT'"
body d3 'Owns: src/xy/a.ts'
OUT=$("$LINT" 1="$L/d1.md" 2="$L/d3.md")
[ "$OUT" = 'DECOMPOSE_LINT ok 2 children' ] && ok || bad "A3-dir src/x/ does not hold src/xy/a.ts: '$OUT'"
body none 'Order: 1 of 2'
OUT=$("$LINT" 1="$L/none.md" 2="$L/a.md")
[ "$OUT" = 'DECOMPOSE_LINT no-owns 1' ] && ok || bad "A3 a body with no Owns: is named, and 'ok' is not printed: '$OUT'"
# The board lane's HTML body (fc-board.sh _fcb_html shape).
printf '<p>Body.</p>\n<p>---<br>Part of #9<br>Blocked-by: LG-41 (hard)<br>Owns: src/board.tsx</p>\n' > "$L/h2.html"
printf '<p>Body.</p>\n<p>---<br>Owns: src/board.tsx</p>\n' > "$L/h1.html"
OUT=$("$LINT" LG-41="$L/h1.html" LG-42="$L/h2.html")
[ "$OUT" = 'DECOMPOSE_LINT ok 2 children' ] && ok || bad "A3 a board HTML body with Blocked-by (hard) is linked: '$OUT'"
OUT=$("$LINT" LG-40="$L/h1.html" LG-42="$L/h2.html")
[ "$OUT" = 'DECOMPOSE_LINT owns-overlap src/board.tsx LG-40 LG-42' ] && ok || bad "A3 a board HTML body is read: '$OUT'"
"$LINT" >/dev/null 2>&1; [ $? -eq 2 ] && ok || bad "A3 no arguments is a usage error, rc 2"
"$LINT" "$L/a.md" >/dev/null 2>&1; [ $? -eq 2 ] && ok || bad "A3 an argument without id= is a usage error, rc 2"

# ===========================================================================
# A1-board. the board lane's filer writes Owns: into the description too
# ===========================================================================
BH="$T/bh"
mkdir -p "$BH/bin/lib" "$BH/logs" "$BH/env" "$BH/prompts" "$T/stub"
model_routes_fixture "$BH" lg-os || exit 1
cp "$DIR/bin/fleet-conf.sh" "$BH/bin/"
printf 'lg-os  example-org/lg-os  https://lg.example  /api/board  3 box-1\n' > "$BH/fleet.conf"
: > "$BH/env/global.env"
printf 'LG_INTERNAL_API_TOKEN=tok-fixture-6384\nLG_API_BASE=https://lg.example\n' > "$BH/env/lg-os.env"
cat > "$T/stub/curl" <<'SH'
printf '%s\n' "$*" >> "$CURL_LOG"
seq=$(wc -l < "$CURL_LOG" | tr -d ' ')
method=GET; url=""; data=""; k=""
while [ $# -gt 0 ]; do
  case "$1" in
    -X) method="$2"; shift ;;
    --data-binary) data="$2"; shift ;;
    -d) shift ;;
    -H) case "$2" in Idempotency-Key:*) k="${2##*-}" ;; esac; shift ;;
    http*) url="$1" ;;
  esac
  shift
done
[ -n "$data" ] && cp "${data#@}" "$CURL_BODIES/$seq.json"
case "$method $url" in
  "GET "*/boards) printf '[{"id":"bd-1","capabilities":["reactions"]}]\n' ;;
  "GET "*/boards/bd-1/tickets) printf '{"tickets":[]}\n' ;;
  "GET "*/tickets/p9) printf '{"ticket":{"id":"p9","key":"LG-9","priority":"high","boardId":"bd-1"}}\n' ;;
  "POST "*/boards/bd-1/tickets) printf '{"ticket":{"id":"c%s","key":"LG-%s"}}\n' "$k" "$((40 + k))" ;;
  "POST "*/comments) printf '{"ok":true}\n' ;;
  "POST "*/move) printf '{"ticket":{"status":"in_progress"}}\n' ;;
  *) exit 22 ;;
esac
exit 0
SH
chmod +x "$T/stub/curl"
BB="$T/bb"; mkdir -p "$BB" "$T/bodies"; : > "$T/curl.log"
printf '%s\n' "$SPEC_OV" > "$BB/children.json"
env HARNESS="$BH" FLEET_CONF="$BH/fleet.conf" PATH="$T/stub:$PATH" CURL_LOG="$T/curl.log" CURL_BODIES="$T/bodies" \
  bash -c '. "$1/bin/lib/file-children.sh" || exit 9; file_children lg-os p9 LG-9 "$2" "$2/children.json"' _ "$DIR" "$BB" >/dev/null 2>&1
RC=$?
[ "$RC" -eq 0 ] && ok || bad "A1-board the board filer files the spec (rc=$RC)"
SEQ=$(grep -n -- "-X POST .*/boards/bd-1/tickets\$" "$T/curl.log" | sed -n 2p | cut -d: -f1)
D2=$(jq -r '.description // empty' "$T/bodies/$SEQ.json" 2>/dev/null)
grep -qF 'Owns: src/board.tsx, src/board/filters.ts</p>' <<<"$D2" && ok || bad "A1-board child 2 description carries Owns: after the footer: $D2"
grep -qF 'Owns:' <<<"$(jq -r '.description // empty' "$T/bodies/$(grep -n -- "-X POST .*/boards/bd-1/tickets\$" "$T/curl.log" | sed -n 1p | cut -d: -f1).json")" \
  && ok || bad "A1-board the contract's own owns is written too"

# ===========================================================================
# A2. the Verify list is not counted as planned (BH-6299, pinned here)
# ===========================================================================
mkdir -p "$T/a2"
cat > "$T/a2/plan.md" <<'MD'
# Plan
## Files to touch
1. `src/a.ts` — the change.
## Verify (run, not edited)
- `tests/unit/x.test.ts`
## Tasks
### T1
Edit `src/a.ts`.
VALIDATE: `npx vitest run tests/unit/x.test.ts` passes.
MD
"$DIR/bin/planned-files.sh" "$T/a2" >/dev/null 2>&1; RC=$?
[ "$RC" -eq 0 ] && ok || bad "A2 planned-files rc=$RC"
PF=$(cat "$T/a2/planned-files.txt" 2>/dev/null)
grep -qx 'src/a.ts' <<<"$PF" && ok || bad "A2 the real edit is planned: $PF"
grep -qx 'tests/unit/x.test.ts' <<<"$PF" && bad "A2 the Verify-list file is not planned: $PF" || ok

# ===========================================================================
# A4. HUB_MODULE
# ===========================================================================
R="$T/repo"; mkdir -p "$R/bin" "$R/src/dir"
git -C "$R" init -q 2>/dev/null
printf 'echo a\n' > "$R/bin/a.sh"; printf 'b\n' > "$R/bin/b.sh"; printf 'x\n' > "$R/src/dir/f.ts"
git -C "$R" add -A && git -C "$R" -c user.email=t@example.com -c user.name=t commit -qm init
HM="$T/hm"; mkdir -p "$HM/bin"
NOW=1791849600   # 2026-10-13 00:00:00Z, pinned
hmw() { HARNESS="$HM" "$HMW" scoutish --repo "$R" "$@"; }
idx() { printf '%s\n' "$@" > "$T/idx.tsv"; }
hm_lines() { cat "$HM/logs/scoutish.log" 2>/dev/null | grep -c ' HUB_MODULE '; }
reset_hm() { scratch_rm "$T/hm/logs"; scratch_rm "$T/hm/state"; }

reset_hm
idx $'TK-1\tsha\t-\tbin/a.sh|src/new.ts' $'TK-2\tsha\t-\tbin/a.sh' $'TK-3\tsha\t-\tsrc/new.ts|bin/a.sh|bin/b.sh'
hmw --index "$T/idx.tsv" --now "$NOW"; RC=$?
[ "$RC" -eq 0 ] && ok || bad "A4 rc=$RC"
[ "$(hm_lines)" = 1 ] && ok || bad "A4 exactly one HUB_MODULE line: $(cat "$HM/logs/scoutish.log" 2>/dev/null)"
grep -qx '2026-10-13 00:00:00Z HUB_MODULE bin/a.sh 3 tickets (TK-1,TK-2,TK-3)' "$HM/logs/scoutish.log" \
  && ok || bad "A4 the line names the file, the count and the keys: $(cat "$HM/logs/scoutish.log" 2>/dev/null)"

reset_hm; idx $'TK-1\tsha\t-\tbin/a.sh' $'TK-2\tsha\t-\tbin/a.sh'
hmw --index "$T/idx.tsv" --now "$NOW"
[ "$(hm_lines)" = 0 ] && ok || bad "A4-neg-2 two tickets is not a hub"

reset_hm; idx $'TK-1\tsha\t-\tsrc/new.ts' $'TK-2\tsha\t-\tsrc/new.ts' $'TK-3\tsha\t-\tsrc/new.ts'
hmw --index "$T/idx.tsv" --now "$NOW"
[ "$(hm_lines)" = 0 ] && ok || bad "A4-neg-new a path not in HEAD is not a hub"

reset_hm; idx $'TK-1\tsha\t-\tsrc/dir' $'TK-2\tsha\t-\tsrc/dir' $'TK-3\tsha\t-\tsrc/dir'
hmw --index "$T/idx.tsv" --now "$NOW"
[ "$(hm_lines)" = 0 ] && ok || bad "A4-neg-dir a bare directory is not a hub"

reset_hm; idx $'TK-1\tsha\t-\tbin/a.sh|bin/a.sh' $'TK-1\tsha\t-\tbin/a.sh' $'TK-2\tsha\t-\tbin/a.sh'
hmw --index "$T/idx.tsv" --now "$NOW"
[ "$(hm_lines)" = 0 ] && ok || bad "A4-dup one key listed three times counts once"

reset_hm; idx $'TK-1\tsha\t-\tbin/a.sh' $'TK-2\tsha\t-\tbin/a.sh' $'TK-3\tsha\t-\tbin/a.sh' $'TK-4\tsha\t-\tbin/a.sh'
hmw --index "$T/idx.tsv" --now "$NOW"
grep -q ' HUB_MODULE bin/a.sh 4 tickets ' "$HM/logs/scoutish.log" && ok || bad "A4 four tickets fire with n=4"

# The daily stamp, through the real jobs-client path (a stub preplan_index).
cat > "$HM/bin/jobs-client.sh" <<'SH'
preplan_index() { echo "$1" >> "$HM_CALLS"; [ "${HM_FAIL:-0}" = 1 ] && return 1; cat "$HM_IDX"; }
SH
reset_hm; : > "$T/calls"
idx $'TK-1\tsha\t-\tbin/a.sh' $'TK-2\tsha\t-\tbin/a.sh' $'TK-3\tsha\t-\tbin/a.sh'
export HM_CALLS="$T/calls" HM_IDX="$T/idx.tsv"
hmw --now "$NOW"
[ "$(wc -l < "$T/calls")" = 1 ] && ok || bad "A4-daily the first run of the day reads the index once"
[ "$(hm_lines)" = 1 ] && ok || bad "A4-daily the first run writes the line"
hmw --now $((NOW + 3600))
[ "$(wc -l < "$T/calls")" = 1 ] && ok || bad "A4-daily a second run the same day makes no read"
[ "$(hm_lines)" = 1 ] && ok || bad "A4-daily a second run the same day writes no new line"
hmw --now $((NOW + 86400))
[ "$(wc -l < "$T/calls")" = 2 ] && ok || bad "A4-next-day the next UTC day reads again"
[ "$(hm_lines)" = 2 ] && ok || bad "A4-next-day the next UTC day writes its line"

reset_hm; : > "$T/calls"
HM_FAIL=1 hmw --now "$NOW"; RC=$?
[ "$RC" -eq 0 ] && ok || bad "A4 an unreachable index is rc 0"
grep -q 'HUB_MODULE_SKIPPED scoutish index-unreachable' "$HM/logs/scoutish.log" && ok || bad "A4 an unreachable index is logged"
HM_FAIL=1 hmw --now $((NOW + 60))
[ "$(wc -l < "$T/calls")" = 1 ] && ok || bad "A4 a dead index is read once a day, not once a tick"

reset_hm
HARNESS="$HM" "$HMW" scoutish --repo "$T/no-such-repo" --index "$T/idx.tsv" --now "$NOW"; RC=$?
[ "$RC" -eq 0 ] && grep -q 'HUB_MODULE_SKIPPED scoutish no-checkout' "$HM/logs/scoutish.log" \
  && ok || bad "A4 no checkout is rc 0 and logged (rc=$RC)"
HARNESS="$HM" "$HMW" >/dev/null 2>&1; [ $? -eq 2 ] && ok || bad "A4 no project is a usage error, rc 2"

# --box runs it for every project of this box.
printf '#!/bin/bash\necho box-1\n' > "$HM/bin/box-name.sh"; chmod +x "$HM/bin/box-name.sh"
cp "$DIR/bin/fleet-conf.sh" "$DIR/bin/box-for.sh" "$HM/bin/"
reset_hm; : > "$T/calls"
HARNESS="$HM" FLEET_CONF="$H/fleet.conf" REPOS_ROOT="$T/repos" "$HMW" --box; RC=$?
[ "$RC" -eq 0 ] && ok || bad "A4 --box rc=$RC"
grep -q 'HUB_MODULE_SKIPPED scoutish no-checkout' "$HM/logs/scoutish.log" 2>/dev/null \
  && ok || bad "A4 --box ran the box's project (scoutish has no checkout under REPOS_ROOT)"

# A4-wired: the real pre-plan tick calls it with --box, before any early exit.
PT="$T/pt"; mkdir -p "$PT/bin" "$PT/logs"
printf '#!/bin/bash\necho "$*" >> "%s/hmw.calls"\nexit 7\n' "$T" > "$PT/bin/hub-module-warn.sh"
chmod +x "$PT/bin/hub-module-warn.sh"
: > "$T/hmw.calls"
HARNESS="$PT" PREPLAN_SPECULATIVE=0 bash "$DIR/bin/preplan-tick.sh" >/dev/null 2>&1; RC=$?
[ "$(cat "$T/hmw.calls")" = '--box' ] && ok || bad "A4-wired preplan-tick calls hub-module-warn.sh --box once: '$(cat "$T/hmw.calls")'"
[ "$RC" -eq 0 ] && ok || bad "A4-wired a failing hub-module-warn.sh does not change the tick's rc (rc=$RC)"

# ===========================================================================
# M1-M3. the overlap report
# ===========================================================================
RH="$T/rh"; mkdir -p "$RH/builds" "$RH/state" "$T/ghstub"
mkp() { # mkp <dir> <contract line> <keys...>
  local d="$RH/builds/$1"; shift; local c="$1"; shift
  mkdir -p "$d/children"; printf 'DECOMPOSED %s\n' "$(IFS=,; echo "$*")" > "$d/RESULT"
  printf '%s\n' "$@" > "$d/children.txt"
  printf 'Body.\n\n---\nPart of #1\nOrder: 1 of %s\nCONTRACT: %s\n' "$#" "$c" > "$d/children/child-1.md"
  printf '{"project":"scoutish","ticket_id":"1","key":"TK-1"}\n' > "$d/job.json"
}
mkp scoutish-TK-10-202610120000 'src/seams/a.ts: seam for TK-10.1; src/seams/b.ts: seam' TK-11 TK-12 TK-13 TK-14
mkp scoutish-TK-20-202610120100 'src/x.ts: x()' TK-21 TK-22 TK-23
# gh stub: answers gh_rest's `gh api -i -X GET <path>` with REST JSON.
cat > "$T/ghstub/gh" <<'SH'
#!/bin/bash
p=""; for a in "$@"; do case "$a" in repos/*) p="$a" ;; esac; done
echo "$p" >> "$GH_CALLS"
pr() { printf 'HTTP/2.0 200 OK\r\n\r\n%s\n' "$1"; }
case "$p" in
  *head=example-org:ticket/TK-12*) pr '[{"number":12,"merged_at":"2026-10-12T01:00:00Z"}]' ;;
  *head=example-org:ticket/TK-13*) pr '[{"number":13,"merged_at":"2026-10-12T01:00:00Z"}]' ;;
  *head=example-org:ticket/TK-14*) pr '[{"number":14,"merged_at":null}]' ;;
  *head=example-org:ticket/TK-22*) pr '[{"number":22,"merged_at":"2026-10-12T01:00:00Z"}]' ;;
  *head=example-org:ticket/TK-23*) printf 'HTTP/2.0 502 Bad Gateway\r\n\r\n{}\n' ;;
  *head=example-org:ticket/TK-11*) pr '[{"number":11,"merged_at":"2026-10-12T00:30:00Z"}]' ;;
  */pulls/11/files*) pr '[{"filename":"src/seams/a.ts"},{"filename":"src/seams/b.ts"}]' ;;
  */pulls/12/files*) pr '[{"filename":"src/run.ts"},{"filename":"src/seams/a.ts"}]' ;;
  */pulls/13/files*) pr '[{"filename":"src/run.ts"},{"filename":"src/seams/a.ts"},{"filename":"src/c.ts"}]' ;;
  */pulls/22/files*) pr '[{"filename":"src/y.ts"}]' ;;
  *head=*) pr '[]' ;;
  *) printf 'HTTP/2.0 404 Not Found\r\n\r\n{}\n' ;;
esac
SH
chmod +x "$T/ghstub/gh"
: > "$T/gh.calls"
OUT=$(env HARNESS="$RH" FLEET_CONF="$H/fleet.conf" PATH="$T/ghstub:$PATH" GH_CALLS="$T/gh.calls" GH_ETAG=0 \
      "$REP" before --projects scoutish 2>&1); RC=$?
[ "$RC" -eq 0 ] && ok || bad "M1 rc=$RC: $OUT"
R10=$(grep '^scoutish	scoutish-TK-10-' <<<"$OUT")
[ "$(cut -f4 <<<"$R10")" = 'src/run.ts' ] && ok || bad "M1 parent 1 overlap is src/run.ts only (the seam is excluded): '$R10'"
[ "$(cut -f5 <<<"$R10")" = 1 ] && ok || bad "M1 parent 1 has 1 unmerged sibling (TK-14 closed unmerged): '$R10'"
R20=$(grep '^scoutish	scoutish-TK-20-' <<<"$OUT")
[ "$(cut -f4 <<<"$R20")" = '-' ] && ok || bad "M1 parent 2 has no overlap: '$R20'"
[ "$(cut -f7 <<<"$R20")" = 1 ] && ok || bad "M1 parent 2 counts the failed read apart (unread=1): '$R20'"
grep -qx 'REPORT before parents=2 with_overlap=1 fallback_parents=- unmeasured=2' <<<"$OUT" \
  && ok || bad "M1 summary: $(tail -1 <<<"$OUT")"
for k in 12 13 14 22 23; do grep -q "ticket/ts-$k&" "$T/gh.calls" || bad "M1 sibling TK-$k is looked up"; done; ok
grep -qE 'ticket/ts-(10|11|20|21)&' "$T/gh.calls" && bad "M1 the parent and the contract child are not siblings" || ok

# M2: after, with children.json already in the replay dirs — no model call.
mkdir -p "$RH/state/decompose-replay/scoutish-TK-10-202610120000" "$RH/state/decompose-replay/scoutish-TK-20-202610120100"
printf '%s\n' "$SPEC_OV" > "$RH/state/decompose-replay/scoutish-TK-10-202610120000/children.json"
printf '%s\n' "$SPEC_OWNS" > "$RH/state/decompose-replay/scoutish-TK-20-202610120100/children.json"
mkdir -p "$RH/bin"; printf '#!/bin/bash\necho call >> "%s/rep-agent.calls"\n' "$T" > "$RH/bin/agent-call.sh"; chmod +x "$RH/bin/agent-call.sh"
: > "$T/rep-agent.calls"
OUT=$(HARNESS="$RH" "$REP" after --projects scoutish 2>&1); RC=$?
[ "$RC" -eq 0 ] && ok || bad "M2 rc=$RC: $OUT"
A10=$(grep '^scoutish	scoutish-TK-10-' <<<"$OUT")
[ "$(cut -f4 <<<"$A10")" = 'src/board.tsx' ] && ok || bad "M2 an unlinked owns overlap is reported: '$A10'"
[ "$(cut -f6 <<<"$A10")" = 1 ] && ok || bad "M2 fallback_count=1 for the 'same file' entry: '$A10'"
A20=$(grep '^scoutish	scoutish-TK-20-' <<<"$OUT")
[ "$(cut -f4,6 <<<"$A20")" = '-	0' ] && ok || bad "M2 disjoint owns: no overlap, no fallback: '$A20'"
grep -qx 'REPORT after parents=2 with_overlap=1 fallback_parents=1 unmeasured=0' <<<"$OUT" \
  && ok || bad "M2 summary: $(tail -1 <<<"$OUT")"
[ -s "$T/rep-agent.calls" ] && bad "M2 a replay dir with children.json is never re-bought" || ok

# M3: after, a parent with no children.json, no --yes: zero calls.
scratch_rm "$RH/state/decompose-replay/scoutish-TK-20-202610120100/children.json"
OUT=$(HARNESS="$RH" "$REP" after --projects scoutish 2>&1); RC=$?
[ "$RC" -eq 0 ] && ok || bad "M3 rc=$RC"
grep -q 'REPORT after-plan parents=2 model_calls=1' <<<"$OUT" && ok || bad "M3 the plan line counts one call: $OUT"
grep -q 'REPLAY needs-call .*scoutish-TK-20-' <<<"$OUT" && ok || bad "M3 the parent that needs a call is named: $OUT"
[ -s "$T/rep-agent.calls" ] && bad "M3 no --yes, no model call" || ok
"$REP" sideways >/dev/null 2>&1; [ $? -eq 2 ] && ok || bad "M usage error is rc 2"
# M4: no --projects: the project list is bin/fleet-conf.sh --projects, never a
#   literal in the script (tests/fleet-projects-not-hardcoded-test.sh).
OUT=$(env HARNESS="$RH" FLEET_CONF="$H/fleet.conf" "$REP" after 2>&1); RC=$?
[ "$RC" -eq 0 ] && grep -q 'REPORT after-plan parents=2 model_calls=1' <<<"$OUT" \
  && ok || bad "M4 with no --projects the fleet's projects (scoutish) are read: rc=$RC $OUT"
# M4b: an empty fleet answer is not "no projects": rc 1, a named reason, no REPORT.
: > "$T/empty-fleet.conf"
OUT=$(env HARNESS="$RH" FLEET_CONF="$T/empty-fleet.conf" "$REP" after 2>&1); RC=$?
[ "$RC" -eq 1 ] && grep -q 'fleet-conf.sh --projects' <<<"$OUT" && ! grep -q '^REPORT' <<<"$OUT" \
  && ok || bad "M4b an empty fleet list stops the run with rc 1: rc=$RC $OUT"
# M5: a pool parent relayed from a Fly box has only RESULT (no children.txt,
#   no children/child-1.md). Its keys come from the RESULT line (land order,
#   contract first) and its seams from the contract child's merged PR files.
PD="$RH/builds/pool-scoutish-TK-10-202610120300"; mkdir -p "$PD"
printf 'DECOMPOSED TK-11,TK-12,TK-13,TK-14\nBUILD_DIR: scoutish-TK-10-202610120250\n' > "$PD/RESULT"
printf '{"project":"scoutish","ticket_id":"1","key":"TK-10"}\n' > "$PD/job.json"
: > "$T/gh.calls"
OUT=$(env HARNESS="$RH" FLEET_CONF="$H/fleet.conf" PATH="$T/ghstub:$PATH" GH_CALLS="$T/gh.calls" GH_ETAG=0 \
      "$REP" before "$PD" 2>&1); RC=$?
R5=$(grep '^scoutish	pool-scoutish-TK-10-' <<<"$OUT")
[ "$RC" -eq 0 ] && [ "$(cut -f3 <<<"$R5")" = 4 ] && ok || bad "M5 the RESULT line gives 4 keys: rc=$RC '$R5'"
[ "$(cut -f4 <<<"$R5")" = 'src/run.ts' ] && ok || bad "M5 the overlap excludes the contract PR's files (seams): '$R5'"
grep -q 'ticket/TK-11&' "$T/gh.calls" && ok || bad "M5 the contract child's PR is read for the seams"
# M6: a project whose name is a prefix of another (scoutish, scoutish-os) does
#   not list the other's parent twice.
printf 'scoutish     example-org/scoutish  https://s.example  -  9 box-1\nscoutish-os  example-org/s-os     https://o.example  -  9 box-1\n' > "$T/two-fleet.conf"
mkdir -p "$RH/builds/pool-scoutish-os-TK-40-202610120400"
printf 'DECOMPOSED TK-41,TK-42\n' > "$RH/builds/pool-scoutish-os-TK-40-202610120400/RESULT"
OUT=$(env HARNESS="$RH" FLEET_CONF="$T/two-fleet.conf" "$REP" after 2>&1); RC=$?
[ "$(grep -c 'REPLAY needs-call .*pool-scoutish-os-TK-40-' <<<"$OUT")" = 1 ] && ok \
  || bad "M6 a parent is listed once when one project name prefixes another: $OUT"

echo "plan-contract-seams (BH-6384): $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
