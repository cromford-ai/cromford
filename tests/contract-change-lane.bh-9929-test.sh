#!/bin/bash
# tests/contract-change-lane.bh-9929-test.sh — BH-9929 T5 (acceptance A6).
#
# A contract-change master files 3 step children (expand, migrate, contract)
# instead of buying a plan. Driven through the production block: the
# `# >>> contract-change hook (BH-9929)` of bin/lib/rb/plan.sh, extracted by its
# markers and run under bash against a scratch harness with the REAL
# bin/lib/contract-change.sh, bin/lib/fc-contract-change.sh and
# bin/lib/file-children.sh, and a lane-module stub (bin/lib/fc-issues.sh) beside
# them that records the spec and writes fake issue numbers to children.txt —
# the test seam the rollout suites use. 0 network calls.
#
#   N1  a master (label) files 3 children: titles, Contract-step lines,
#       Contract-parent, the `after` chain the filer turns into
#       `Blocked-by: #<prev> (hard)`, RESULT ROLLOUT_FILED 3, no plan
#   N2  a rerun files 0 (the record holds 3)
#   N3  a record with 1 of 3 resumes: the filer is entered with 1 on the record
#       and files the 2 missing steps
#   N4  the switch off: nothing filed, falls through to the ordinary plan
#   N5  a child body (Contract-step:) is not re-split; the step note block
#       puts the step into UI_PLAN_NOTE
#   N6  a body with both a rollout section and the marker is refused once
#   N7  an ordinary ticket: the block does nothing
#   N8  a filer that records 2 of 3 is ROLLOUT_FAILED, never FILED
#   N9  the child body of each step feeds cc_step_of (writer/reader round-trip)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "contract-change-lane: jq is required"; exit 1; }

. "$DIR/tests/lib/rb-all.sh" || exit 1
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh") || exit 1
awk '/^# >>> contract-change hook \(BH-9929\)/{f=1;next} /^# <<< contract-change hook \(BH-9929\)/{exit} f' "$RB_ALL" > "$T/hook.sh"
awk '/^# >>> contract-step note \(BH-9929\)/{f=1;next} /^# <<< contract-step note \(BH-9929\)/{exit} f' "$RB_ALL" > "$T/note.sh"
[ -s "$T/hook.sh" ] && [ -s "$T/note.sh" ] && ok || bad "N0 could not extract the plan.sh blocks"
# the hook sits above the rollout hook, the note after the web-task hook
HL=$(grep -n '^# >>> contract-change hook (BH-9929)' "$RB_ALL" | cut -d: -f1)
RL=$(grep -n '^# >>> rollout hook' "$RB_ALL" | cut -d: -f1)
NL=$(grep -n '^# >>> contract-step note (BH-9929)' "$RB_ALL" | cut -d: -f1)
UL=$(grep -n '^UI_PLAN_NOTE=""' "$RB_ALL" | head -1 | cut -d: -f1)
[ -n "$HL" ] && [ -n "$RL" ] && [ "$HL" -lt "$RL" ] && ok || bad "N0 the hook must sit above the rollout hook ($HL vs $RL)"
[ -n "$NL" ] && [ -n "$UL" ] && [ "$NL" -gt "$UL" ] && ok || bad "N0 the note must come after UI_PLAN_NOTE is set ($NL vs $UL)"

H="$T/h"; mkdir -p "$H/bin/lib" "$H/state"
# scratch-closure-allow: the plan.sh hook is extracted and run alone against a scratch harness with a lane-module stub beside these real libs
cp "$DIR/bin/lib/contract-change.sh" "$DIR/bin/lib/fc-contract-change.sh" "$DIR/bin/lib/file-children.sh" \
   "$DIR/bin/lib/lane-gate.sh" "$H/bin/lib/"
cp "$DIR/bin/fleet-conf.sh" "$DIR/bin/run-rollout.sh" "$H/bin/"
cat > "$H/fleet.conf" <<'CONF'
# <project> <repo> <prod> <board-api-prefix> <offset> [box] [ip]
project-3      example-org/project-3   https://project-3.example  -  9 box-1 192.0.2.9
project-1  example-org/mom    https://mom.example   -  9 box-1 192.0.2.9
CONF
# the lane-module stub: records the spec, files the missing children
cat > "$H/bin/lib/fc-issues.sh" <<'SH'
#!/bin/bash
fc_file_issues() {
  local n k done_n
  done_n=$(grep -c '[^[:space:]]' "$FC_BUILD/children.txt" 2>/dev/null || true)
  case "${done_n:-}" in ''|*[!0-9]*) done_n=0 ;; esac
  printf 'kind=%s parent=%s key=%s resume_from=%s\n' "$FC_KIND" "$FC_PARENT" "$FC_KEY" "$done_n" >> "$FC_BUILD/filer-call.txt"
  n=$(jq 'length' "$FC_SPEC"); k=$((done_n + 1))
  while [ "$k" -le "$n" ]; do
    [ "$k" = "${STUB_STOP_AT:-}" ] && return 1
    printf '%s\n' "$((900 + k))" >> "$FC_BUILD/children.txt"; k=$((k + 1))
  done
  return 0
}
SH
REG="$T/lanes.json"
"$DIR/bin/lanes-build.sh" --root "$DIR" --to "$REG" >/dev/null 2>&1 || bad "N0 lanes-build could not compose the registry"
jq -nc '{fetched_at:1700000000, values:{"lib.contract-change.project-3.contract_change_enabled":"1"}, seeded:{}}' > "$H/state/settings-cache.json"

# hook <build> <project> <title> <labels-json> <body> — run the hook, then the
# note block; prints the RESULT line or PLANNED (fell through), then the note.
hook() {
  local b="$1" p="$2" title="$3" labels="$4" body="$5"
  mkdir -p "$b"
  jq -n --arg t "$title" --argjson l "$labels" --arg b "$body" '{title:$t, labels:$l, body:$b}' > "$b/ticket-meta.json"
  ( env HARNESS="$H" BUILD="$b" FLEET_CONF="$H/fleet.conf" LANE_REGISTRY="$REG" LANE_GATE_NOW=1700000010 \
        P="$p" STUB_STOP_AT="${STUB_STOP_AT:-}" bash -c '
      set -uo pipefail
      STAMP() { echo TS; }
      RESULT() { printf "RESULT %s\n" "$*"; }
      PROJECT=$P; KEY=BH-55; TICKET=55
      . "$0"
      UI_PLAN_NOTE=""
      . "$0.note"
      echo "PLANNED"
      printf "NOTE=%s\n" "$UI_PLAN_NOTE"
    ' "$T/hook.sh" ) > "$b/out.txt" 2>&1
}
cp "$T/note.sh" "$T/hook.sh.note"
res()   { grep '^RESULT ' "$1/out.txt" | tail -1; }
keys()  { grep -c '[^[:space:]]' "$1/children.txt" 2>/dev/null || echo 0; }
calls() { grep -c . "$1/filer-call.txt" 2>/dev/null || echo 0; }

MASTER_BODY=$'Drop the CHECK on report_choice.kind and move the values to a lookup table.\n\nScope: report_choice'
# ── N1 ───────────────────────────────────────────────────────────────────────
B="$T/b1"
hook "$B" project-3 "Contract: report_choice kinds" '[{"name":"ai-build"},{"name":"contract-change"}]' "$MASTER_BODY"
[ "$(res "$B")" = "RESULT ROLLOUT_FILED 3" ] && ok || bad "N1 RESULT: [$(res "$B")] $(cat "$B/out.txt")"
grep -q '^PLANNED' "$B/out.txt" && bad "N1 a master must not reach the plan" || ok
[ "$(keys "$B")" = 3 ] && ok || bad "N1 3 children on the record: $(keys "$B")"
grep -qx 'kind=rollout parent=55 key=BH-55 resume_from=0' "$B/filer-call.txt" && ok || bad "N1 filer call: $(cat "$B/filer-call.txt")"
[ "$(jq -r 'map(.title) | join("|")' "$B/children.json")" = "expand — Contract: report_choice kinds|migrate — Contract: report_choice kinds|contract — Contract: report_choice kinds" ] \
  && ok || bad "N1 titles: $(jq -c 'map(.title)' "$B/children.json")"
[ "$(jq -c 'map(.after)' "$B/children.json")" = '[[],[1],[2]]' ] && ok || bad "N1 the after chain: $(jq -c 'map(.after)' "$B/children.json")"
for i in 0 1 2; do
  s=$(jq -r ".[$i].title | split(\" \")[0]" "$B/children.json")
  jq -r ".[$i].body" "$B/children.json" > "$T/cb.md"
  # N9: the writer's lines through the readers
  [ "$(. "$DIR/bin/lib/contract-change.sh"; cc_step_of "$T/cb.md")" = "$s" ] && ok || bad "N9 child $i: cc_step_of != $s"
  [ "$(. "$DIR/bin/lib/contract-change.sh"; cc_parent_of "$T/cb.md")" = 55 ] && ok || bad "N9 child $i: cc_parent_of"
  grep -qF 'Drop the CHECK on report_choice.kind' "$T/cb.md" && ok || bad "N1 child $i must carry the parent scope"
done
jq -r '.[2].body' "$B/children.json" | grep -qF 'BACKUP:' && ok || bad "N1 the contract child must name the BACKUP line"
jq -r '.[1].body' "$B/children.json" | grep -qF 'BACKFILL-COUNTS:' && ok || bad "N1 the migrate child must name the counts line"
# the real filer turns `after` into the hard Blocked-by chain (rollout footer)
F=$(. "$DIR/bin/lib/file-children.sh"; fc_child_footer rollout 55 2 3 "#901 (hard)" "" "")
grep -qx 'Blocked-by: #901 (hard)' <<<"$F" && grep -qx 'Order: 2 of 3' <<<"$F" && grep -qx 'Part of #55' <<<"$F" \
  && ok || bad "N1 the rollout footer: $F"
# ── N2 ───────────────────────────────────────────────────────────────────────
hook "$B" project-3 "Contract: report_choice kinds" '[{"name":"contract-change"}]' "$MASTER_BODY"
[ "$(res "$B")" = "RESULT ROLLOUT_FILED 3" ] && [ "$(keys "$B")" = 3 ] && [ "$(calls "$B")" = 1 ] && ok \
  || bad "N2 a rerun must file 0: keys=$(keys "$B") calls=$(calls "$B")"
# ── N3 ───────────────────────────────────────────────────────────────────────
B="$T/b3"; mkdir -p "$B"
hook "$B" project-3 "C" '[{"name":"contract-change"}]' "$MASTER_BODY"
sed -i '2,$d' "$B/children.txt"; : > "$B/filer-call.txt"
hook "$B" project-3 "C" '[{"name":"contract-change"}]' "$MASTER_BODY"
grep -qx 'kind=rollout parent=55 key=BH-55 resume_from=1' "$B/filer-call.txt" && [ "$(keys "$B")" = 3 ] \
  && [ "$(res "$B")" = "RESULT ROLLOUT_FILED 3" ] && ok || bad "N3 resume: $(cat "$B/filer-call.txt") keys=$(keys "$B")"
# ── N4 ───────────────────────────────────────────────────────────────────────
B="$T/b4"
hook "$B" project-1 "C" '[{"name":"contract-change"}]' "$MASTER_BODY"
[ -z "$(res "$B")" ] && grep -q '^PLANNED' "$B/out.txt" && [ "$(keys "$B")" = 0 ] && ok || bad "N4 switch off must file 0 and plan: $(cat "$B/out.txt")"
grep -qF 'CONTRACT-CHANGE: the lane is off for project-1' "$B/pipeline.log" && ok || bad "N4 one pipeline.log line"
# ── N5 ───────────────────────────────────────────────────────────────────────
B="$T/b5"
hook "$B" project-3 "BH-55.2: migrate — C" '[{"name":"ai-build"}]' $'Contract-parent: #55\nContract-step: migrate\n\nContract-change: yes'
[ -z "$(res "$B")" ] && grep -q '^PLANNED' "$B/out.txt" && [ "$(keys "$B")" = 0 ] && ok || bad "N5 a child must not be re-split: $(cat "$B/out.txt")"
grep -q '^NOTE=CONTRACT-CHANGE STEP (BH-9929): this ticket is the migrate step of contract-change #55' "$B/out.txt" \
  && grep -qF "$B/contract-step.md" "$B/out.txt" && ok || bad "N5 the step note: $(grep NOTE "$B/out.txt")"
# ── N6 ───────────────────────────────────────────────────────────────────────
B="$T/b6"
hook "$B" project-3 "C" '[]' $'Contract-change: yes\n\n## Rollout\n\n### Wave 1\nfirst\n\n### Wave 2\nsecond\n'
grep -q '^RESULT ROLLOUT_FAILED contract-change: the body carries both a rollout section' "$B/out.txt" && [ "$(keys "$B")" = 0 ] \
  && ok || bad "N6 both markers must be refused: $(cat "$B/out.txt")"
# ── N7 ───────────────────────────────────────────────────────────────────────
B="$T/b7"
hook "$B" project-3 "Add a column" '[{"name":"ai-build"}]' 'Contract-change: no'
[ -z "$(res "$B")" ] && grep -qx 'NOTE=' "$B/out.txt" && [ ! -e "$B/children.json" ] && ok || bad "N7 an ordinary ticket: $(cat "$B/out.txt")"
# ── N8 ───────────────────────────────────────────────────────────────────────
B="$T/b8"
STUB_STOP_AT=3 hook "$B" project-3 "C" '[{"name":"contract-change"}]' "$MASTER_BODY"
grep -q '^RESULT ROLLOUT_FAILED contract-change: filed 2 of 3 steps' "$B/out.txt" && ok || bad "N8 a partial filing is FAILED: $(res "$B")"
# ── N10 (T13) ────────────────────────────────────────────────────────────────
# The lane module is a DECLARED filer caller. The allowlist is read from the
# BH-981 suite itself, so this case and that suite cannot disagree: no bin/
# file outside that allowlist calls the filer, the allowlist names
# bin/lib/fc-contract-change.sh, and the module is sourced (and cc_file_steps
# called) only from the plan.sh contract-change hook.
ALLOW=$(grep -oE "\^bin/lib/file-children\\\\\.sh:[^']*" "$DIR/tests/file-children.bh-981-test.sh" | head -1)
[ -n "$ALLOW" ] && ok || bad "N10 could not read the BH-981 caller allowlist"
grep -qF '^bin/lib/fc-contract-change\.sh:' <<<"$ALLOW" && ok \
  || bad "N10 the BH-981 allowlist must name bin/lib/fc-contract-change.sh: $ALLOW"
CALLERS=$(cd "$DIR" && grep -rn 'file-children\.sh\|file_children\|fc_[a-z_]*(' bin/ fly/ cron/ --include='*.sh' 2>/dev/null \
          | grep -vE "$ALLOW" | grep -vE '^bin/lib/fc-contract-change\.sh:' | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#')
[ -z "$CALLERS" ] && ok || bad "N10 filer callers outside the allowlist: $CALLERS"
SRC=$(cd "$DIR" && grep -rn 'fc-contract-change\.sh' bin/ fly/ cron/ 2>/dev/null \
      | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' | grep -vE '^bin/lib/fc-contract-change\.sh:' | cut -d: -f1 | sort -u)
[ "$SRC" = "bin/lib/rb/plan.sh" ] && ok || bad "N10 fc-contract-change.sh must be sourced from bin/lib/rb/plan.sh only: $SRC"
STEPS=$(cd "$DIR" && grep -rn 'cc_file_steps' bin/ fly/ cron/ 2>/dev/null \
      | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' | grep -vE '^bin/lib/fc-contract-change\.sh:' | cut -d: -f1 | sort -u)
[ "$STEPS" = "bin/lib/rb/plan.sh" ] && ok || bad "N10 cc_file_steps must be called from bin/lib/rb/plan.sh only: $STEPS"

echo "contract-change-lane.bh-9929: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
