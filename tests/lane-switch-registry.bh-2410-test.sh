#!/bin/bash
# tests/lane-switch-registry.bh-2410-test.sh — the nine C4 kill switches of
# BH-2410 are registered in catalog/switches.d/ before any reader moves to
# lane_switch, and tests/lib/lane-switch-fixture.sh proves a reader both ways.
#
#   L8a each of the nine has catalog/switches.d/<n>.json: name == filename,
#       readers non-empty, sorted and present, box_scoped true, a `what`
#   L8b readers is complete both ways: every listed reader holds <n> on a code
#       line, and every bin/ or fly/ file that reads flags/<n> (`[ -e|-f ]`,
#       `[ ! -e|-f ]`) or calls `lane_switch <n>` is listed
#   L8c no `flag_active <n>` read in bin/ (guarded: the pattern finds
#       automerge-disabled)
#   L8d no writer of flags/<n> in bin/ (guarded: the regex finds
#       pipeline-health.sh's pool-halt- writer and skips shards.sh's alert text)
#   L8e the real bin/switch-migrate.sh --dry-run lists every registered switch
#       and writes nothing
#   L8f/L8g the fixture passes a lane_switch reader and fails a bare [ -f ] one;
#       L8g2 it fails a reader that answers right but never logs the ignored file
# Run from anywhere: tests/lane-switch-registry.bh-2410-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$(dirname "$0")/lib/lane-switch-fixture.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: expected '$3', got '$2'"; fi; }

C4="split-chain-off state-backup-off test-reroute-off triage-health-off triage-shards-off
triage-shard-caps-off triage-spool-age-off vendor-spend-off wake-lanes-off"
REG="$DIR/catalog/switches.d"
nocomment() { grep -v ':[0-9]*:[[:space:]]*#'; }

# L8a
for n in $C4; do
  f="$REG/$n.json"
  [ -f "$f" ] || { bad "L8a $n: no catalog/switches.d/$n.json"; continue; }
  eq "L8a $n name" "$(jq -r '.name' "$f")" "$n"
  eq "L8a $n readers non-empty and sorted" \
     "$(jq -r '(.readers|type=="array") and (.readers|length>0) and (.readers==(.readers|sort))' "$f")" true
  eq "L8a $n box_scoped" "$(jq -r '.box_scoped' "$f")" true
  eq "L8a $n what" "$(jq -r '(.what|type=="string") and (.what|length>0)' "$f")" true
  while IFS= read -r r; do
    [ -f "$DIR/$r" ] && ok || bad "L8a $n reader $r does not exist"
  done < <(jq -r '.readers[]?' "$f")
done

# L8b
for n in $C4; do
  f="$REG/$n.json"; [ -f "$f" ] || { bad "L8b $n: no registry file"; continue; }
  listed=$(jq -r '.readers[]?' "$f")
  for r in $listed; do
    [ -n "$(grep -n -- "$n" "$DIR/$r" 2>/dev/null | nocomment)" ] && ok \
      || bad "L8b $n: listed reader $r has no code line naming it"
  done
  found=$(cd "$DIR" && grep -rnE -- "\[ (! )?-[ef] [^]]*flags/$n([^a-z0-9_-]|$)|lane_switch[[:space:]]+\"?$n([^a-z0-9_-]|$)" bin fly \
            | nocomment | cut -d: -f1 | sort -u)
  [ -n "$found" ] || bad "L8b $n: the read pattern found no reader in bin/ or fly/"
  for r in $found; do
    grep -qxF "$r" <<<"$listed" && ok || bad "L8b $n: $r reads flags/$n but is not in readers"
  done
done

# L8c
[ -n "$(grep -rnE 'flag_active [a-z0-9_-]+' "$DIR/bin" | nocomment | grep 'automerge-disabled')" ] && ok \
  || bad "L8c guard: the flag_active pattern no longer finds automerge-disabled"
for n in $C4; do
  eq "L8c no flag_active $n in bin/" \
     "$(grep -rnE -- "flag_active[[:space:]]+\"?$n([^a-z0-9_-]|$)" "$DIR/bin" | nocomment | wc -l | tr -d ' ')" 0
done

# L8d — a writer is `touch`/`>`/`>>` in command position, not the same words
# inside an alert string.
writer_re() {
  printf '%s' "(^|[;&|{(]|then|do|else)[[:space:]]*touch[[:space:]]+\"?[^ \"]*flags/$1\"?([[:space:];&|)]|\$)|>>?[[:space:]]*\"?[^ \"]*flags/$1\"?([[:space:];&|)]|\$)"
}
[ -n "$(grep -nE -- "$(writer_re 'pool-halt-[^ "]*')" "$DIR/bin/pipeline-health.sh" | nocomment)" ] && ok \
  || bad "L8d guard: the writer regex no longer finds pipeline-health.sh's pool-halt- writer"
alert=$(grep -F 'touch flags/triage-shard-caps-off' "$DIR/bin/lib/rt/shards.sh" | head -1)
[ -n "$alert" ] && ok || bad "L8d guard: shards.sh's alert line naming flags/triage-shard-caps-off is gone"
[ -n "$alert" ] && { grep -qE -- "$(writer_re triage-shard-caps-off)" <<<"$alert" \
  && bad "L8d negative pin: the writer regex matches shards.sh's alert text" || ok; }
for n in $C4; do
  eq "L8d no writer of flags/$n in bin/" \
     "$(grep -rnE -- "$(writer_re "$n")" "$DIR/bin" | nocomment | wc -l | tr -d ' ')" 0
done

# L8e — the production entry point over the full registry, nothing on disk.
lsf_setup || bad "L8e lsf_setup"
env HARNESS="$H" ROWS_FILE="$ROWS_FILE" CALLS="$CALLS" JOBS_BOX=hub-1 \
    "$DIR/bin/switch-migrate.sh" --dry-run > "$T/mig.out" 2>&1
eq "L8e dry-run rc" "$?" 0
for f in "$REG"/*.json; do
  b=$(basename "$f" .json)
  grep -qx "absent $b" "$T/mig.out" && ok || bad "L8e dry-run does not list $b: $(cat "$T/mig.out")"
done
for n in $C4; do
  grep -qx "absent $n" "$T/mig.out" && ok || bad "L8e dry-run does not list C4 switch $n"
done
eq "L8e no PUT" "$(grep -c PUT "$CALLS")" 0
grep -q '^GET /api/settings$' "$CALLS" && ok || bad "L8e the dry-run never read settings through the stub"

# L8f — a reader on lane_switch passes all three cases.
lsf_setup bin/nope-not-a-reader.sh 2>/dev/null && bad "L8f lsf_setup accepted a missing reader" || ok
lsf_setup || bad "L8f lsf_setup"
cat > "$H/bin/toy-reader.sh" <<'SH'
#!/bin/bash
. "$(dirname "$0")/lib/lane-switch.sh" || exit 9
lane_switch toy-off && echo stopped || echo ran
SH
probe() { bash "$H/bin/toy-reader.sh"; }
out=$(lsf_cases toy-off probe stopped ran); rc=$?
eq "L8f lsf_cases rc on a lane_switch reader" "$rc" 0
eq "L8f no FAIL lines" "$out" ""
[ -z "${HARNESS:-}" ] && ok || bad "L8f lsf_cases leaked HARNESS into the caller"

# L8g — a bare [ -f ] reader fails, and case (i) is named.
cat > "$H/bin/toy-reader.sh" <<'SH'
#!/bin/bash
[ -f "$HARNESS/flags/toy-off" ] && echo stopped || echo ran
SH
out=$(lsf_cases toy-off probe stopped ran); rc=$?
[ "$rc" -ne 0 ] && ok || bad "L8g lsf_cases rc 0 on a bare [ -f ] reader"
grep -qF 'FAIL: lsf toy-off (i):' <<<"$out" && ok || bad "L8g case (i) not named: $out"

# L8g2 — a reader that gets every answer right but reads the rows itself, so a
# contradicting file is never logged: case (ii) fails on the missing line alone.
cat > "$H/bin/toy-reader.sh" <<'SH'
#!/bin/bash
v=$(jq -r 'map(select(.key=="switch.toy-off"))[0].value // empty' "$ROWS_FILE")
case "$v" in 1) echo stopped ;; 0) echo ran ;; *) [ -f "$HARNESS/flags/toy-off" ] && echo stopped || echo ran ;; esac
SH
out=$(lsf_cases toy-off probe stopped ran); rc=$?
eq "L8g2 lsf_cases rc on a reader that never logs the ignored file" "$rc" 1
eq "L8g2 only case (ii) fails, on the log" "$out" \
   "FAIL: lsf toy-off (ii): expected 'flags/toy-off ignored' in logs/lane-gate.log, got none"

echo "lane-switch-registry.bh-2410: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
