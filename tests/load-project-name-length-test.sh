#!/bin/bash
# tests/load-project-name-length-test.sh — bin/load-project.sh refuses a project
# name longer than 19 chars, before it writes anything.
#
# THE INCIDENT THIS PINS (2026-10-22). cromford-sandbox-linear (23 chars) and
# cromford-sandbox-jira (21) were loaded. The worker refuses a settings key over
# 64 chars (SETTING_KEY_RE, worker/jobs/src/lib/core.js), and the two names made
# 19 keys of 65-68 chars (lane.fly-pool.<project>.test_impact_gate_fresh_fetch_s).
# tests/lanes-registry-test.sh section 9 went red on main and every merge-queue
# batch failed. The projects were renamed cromford-sbx-linear / cromford-sbx-jira.
#
#   A. a --project of 20 chars: rc 2, REFUSED, fleet.conf and prompts/ unchanged
#   B. a derived name (repo basename) of 20 chars: the same refusal
#   C. a --project of exactly 19 chars passes the guard (rc 0, row written)
#   D. the 19 in the loader fits the lane registry: 19 + the longest
#      project-scoped lane.<id>..<knob> part is <= 64, so a longer knob turns
#      THIS suite red and names the number to change
#   E. every project in fleet.conf is within the limit
#
# gh and the network verbs of git are stubs; the fleet lives in $T.
# Run from anywhere: tests/load-project-name-length-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$(dirname "$0")/lib/rendered.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: got '$2' want '$3'"; fi; }

REAL_GIT=$(command -v git); export REAL_GIT
mkdir -p "$T/stub"
cat > "$T/stub/gh" <<'STUB'
#!/bin/bash
case "$*" in
  *defaultBranchRef.name*) echo main ;;
  "repo view"*)            echo "{}" ;;
  *)                       echo "[]" ;;
esac
exit 0
STUB
cat > "$T/stub/git" <<'STUB'
#!/bin/bash
case "$1" in
  pull|push|fetch) exit 0 ;;
  rev-parse) case "$*" in *origin/*) exec "$REAL_GIT" rev-parse HEAD ;; esac ;;
esac
exec "$REAL_GIT" "$@"
STUB
chmod +x "$T/stub/gh" "$T/stub/git"

ROW_A='alpha         Acme/alpha                 -                                    -   2  box-small'
R="$T/r"
mkdir -p "$R/prompts"
cp -r "$DIR/bin" "$R/bin"
cp "$DIR/prompts/TEMPLATE-GH.md" "$R/prompts/TEMPLATE-GH.md"
printf '%s\n' "$ROW_A" > "$R/fleet.conf"
( cd "$R" && "$REAL_GIT" init -q . && "$REAL_GIT" config user.email t@t \
  && "$REAL_GIT" config user.name t && "$REAL_GIT" add -A && "$REAL_GIT" commit -qm base ) >/dev/null 2>&1

load() { # load [args...] — run the real loader, capture rc + output
  ( cd "$R" && PATH="$T/stub:$PATH" HARNESS="$T/h" bash bin/load-project.sh "$@" ) >"$T/out" 2>&1
  echo $?
}
CONF_BEFORE=$(cat "$R/fleet.conf")
PROMPTS_BEFORE=$(ls "$R/prompts")

# ── A. --project of 20 chars ────────────────────────────────────────────────
N20=abcdefghij-klmnopqrs   # 20
eq "A name is 20 chars" "${#N20}" "20"
RC=$(load acme/widget --project "$N20" --no-bootstrap)
eq "A rc" "$RC" "2"
grep -q "REFUSED: project name '$N20' has 20 chars; the limit is 19" "$T/out" && ok || bad "A no REFUSED line: $(head -3 "$T/out")"
eq "A fleet.conf unchanged" "$(cat "$R/fleet.conf")" "$CONF_BEFORE"
eq "A prompts unchanged" "$(ls "$R/prompts")" "$PROMPTS_BEFORE"

# ── B. derived name (repo basename, lowercased) of 20 chars ─────────────────
RC=$(load Acme/Abcdefghij-Klmnopqrs --no-bootstrap)
eq "B rc" "$RC" "2"
grep -q "REFUSED: project name 'abcdefghij-klmnopqrs' has 20 chars" "$T/out" && ok || bad "B no REFUSED line: $(head -3 "$T/out")"
eq "B fleet.conf unchanged" "$(cat "$R/fleet.conf")" "$CONF_BEFORE"

# ── C. exactly 19 chars passes the guard ────────────────────────────────────
N19=abcdefghij-klmnopqr   # 19
eq "C name is 19 chars" "${#N19}" "19"
RC=$(load acme/widget --project "$N19" --box zzz-box --no-bootstrap)
eq "C rc" "$RC" "0"
grep -q REFUSED "$T/out" && bad "C refused a 19-char name" || ok
grep -q "^$N19 " "$R/fleet.conf" && ok || bad "C no fleet.conf row for $N19"

# ── D. the loader's 19 fits the lane registry ───────────────────────────────
MAX=$(sed -n 's/^MAX_PROJECT_LEN=\([0-9][0-9]*\)$/\1/p' "$DIR/bin/load-project.sh")
eq "D MAX_PROJECT_LEN is 19" "$MAX" "19"
REG=$(rendered_registry)
# The same project-scoped selection as tests/lanes-registry-test.sh section 9.
LONGEST=$(jq -r '.lanes[]|.id as $i|.scope as $s|.knobs[]?|select(.env != null)
  | (if has("project_scoped") then (if .project_scoped == true then "explicit-true" else (.project_scoped|tostring) end) else "true" end) as $p
  | select(($s == "project" and $p != "false") or $p == "explicit-true")
  | "lane.\($i)..\(.env|ascii_downcase)" | length' "$REG" | sort -n | tail -1)
case "$LONGEST" in ''|*[!0-9]*) bad "D could not measure the lane registry ($REG)" ;;
  *) [ $((MAX + LONGEST)) -le 64 ] && ok \
       || bad "D 19 + the longest lane+knob part ($LONGEST) is $((MAX + LONGEST)) > 64: lower MAX_PROJECT_LEN in bin/load-project.sh" ;;
esac

# ── E. every project in fleet.conf is within the limit ──────────────────────
LONG=$(awk -v m="$MAX" 'NF && $1 !~ /^#/ && length($1) > m {print $1 "(" length($1) ")"}' "$DIR/fleet.conf")
eq "E fleet.conf names over $MAX chars" "$LONG" ""

echo "load-project-name-length: $PASS pass / $FAIL fail"
[ "$FAIL" -eq 0 ]
