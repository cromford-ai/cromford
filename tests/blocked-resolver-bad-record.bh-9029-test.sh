#!/bin/bash
# tests/blocked-resolver-bad-record.bh-9029-test.sh — BH-9029 fix 3: a state
# record that does not parse is NAMED on the tick line once per episode, and
# once it is older than BR_BAD_RECORD_QUARANTINE_MIN it is moved to
# state/blocked-resolver/<project>/.bad/, so the next tick has no +index-short.
#
# THE BUG (hub, 2026-11-03). `+index-short` was on every tick: at least one
# record did not parse, the pre-pass counted it, and nothing said which file it
# was or moved it. An operator could not find it, and the mark never cleared.
#
# WHAT IS DRIVEN. Every section runs the real bin/blocked-resolver.sh end to
# end against a scratch $HARNESS (the bh-1512 fixture shape: one conductor row
# with a seeded ABANDONED record, so the pre-pass runs). Assertions read the
# tick line, the log and the files on disk.
#
# Run from anywhere: tests/blocked-resolver-bad-record.bh-9029-test.sh (exit 0 = pass)
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

# ONE clock read for the whole file (bin/test-determinism-lint.sh).
NOW=$(date -u +%s)

H="$T/h"
mkdir -p "$H/bin"
cp "$DIR/bin/blocked-resolver.sh" "$DIR/bin/merge-conductor.sh" "$DIR/bin/fleet-conf.sh" \
   "$DIR/bin/project-of.sh" "$DIR/bin/box-for.sh" "$H/bin/"
# shellcheck source=tests/lib/fixture-harness.sh
. "$DIR/tests/lib/fixture-harness.sh" || exit 1
fx_br_harness "$DIR" "$T" || exit 1
[ -d "$DIR/bin/lib/br" ] || exit 1   # impact: this suite runs when bin/lib/br/ changes
# Every fragment rides with the driver copy, as bin/harness-sync.sh puts them on
# a box, and the profile module that writes the prof: line is installed too.
mkdir -p "$H/bin/blocked-resolver.d" || exit 1
cp "$DIR"/bin/blocked-resolver.d/*.sh "$H/bin/blocked-resolver.d/" || exit 1
scratch_install_closure bin/lib/br/opt/profile.sh "$H" >/dev/null || exit 1
[ -f "$DIR/bin/blocked-resolver.d/bh-9029-discovery-index.sh" ] \
  || bad "0: bin/blocked-resolver.d/bh-9029-discovery-index.sh must exist"

cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
case "\$*" in *contents/.mergify.yml*) printf 'HTTP/1.1 404 Not Found\r\nServer: stub\r\n\r\n{"message":"Not Found"}'; exit 0 ;; esac
printf '%s\n' "\$*" >> "$T/gh.txt"
N=\$(printf '%s' "\$*" | sed -nE 's#.*/(pull|pulls|issues)/([0-9]+).*#\2#p' | head -1)
case "\$*" in
  *"-i -X "*)
    GHT="$T"
    printf 'ticket/ts-%s' "\$N" > "$T/prbranch"
    printf 'TK-%s: a thing' "\$N" > "$T/prtitle"
    printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' > "$T/prhead"
    . "$DIR/tests/lib/gh-rest-stub.sh"; gh_rest_stub "\$@" ;;
  *"issues/"*"/comments"*) echo '[]' ;;
  *"repos/"*"/issues/"*) echo "gh: Not Found (HTTP 404)" >&2; exit 1 ;;
  *"pr close"*)   printf '%s\n' "\$*" >> "$T/closed.txt"; exit 0 ;;
  *"pr comment"*|*"issue comment"*) exit 0 ;;
  *"--json state"*) echo OPEN ;;
  *"/pulls/"*)    echo "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ticket/ts-\$N" ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
cat > "$H/bin/jobs-client.sh" <<EOF
queue_put() { printf '%s\n' "\$*" >> "$T/queue.txt"; echo queued; }
queue_done() { printf 'done %s\n' "\$*" >> "$T/queue.txt"; return 0; }
queue_list() { return 1; }
EOF
touch "$H/flags/fly-pool-tproj"
: > "$T/run.log"

ROWS="$H/state/merge-conductor/pr-state.tsv"
ST="$H/state/blocked-resolver"
LOGF="$H/logs/blocked-resolver.log"
MFT="merge-failed-twice: gh pr merge refused"
ROWADD() { printf '%s\tBLOCKED_HUMAN\t%s\tabc123\tabc123\t-\t%s\t%s\n' "$1" "$NOW" "$2" "$3" >> "$ROWS"; }
LASTTICK() { grep 'tick: candidates=' "$LOGF" | tail -1 | sed -E 's/^[0-9-]+ [0-9:]+Z //'; }
LFIELD() { LASTTICK | sed -nE "s/.*(^| )$1=([^ ]*).*/\2/p"; }
BADF="$ST/tproj/tproj-TK-77.json"
SETUP() {  # SETUP <bad-record-age-secs>
  scratch_rm "$ST" 2>/dev/null
  mkdir -p "$ST/tproj"
  : > "$T/gh.txt"; : > "$T/closed.txt"; : > "$T/queue.txt"; : > "$LOGF"; : > "$ROWS"
  printf '{"project":"tproj","rkey":"tproj-TK-31","outcome":"ABANDONED","attempts":[]}\n' > "$ST/tproj/tproj-TK-31.json"
  printf 'not json at all\n' > "$BADF"
  touch -d "@$((NOW - $1))" "$BADF"
  ROWADD "o/tproj#31" "$MFT" "https://github.com/o/tproj/pull/31"
  ROWADD "o/tproj#32" "$MFT" "https://github.com/o/tproj/pull/32"
  BRENV=(BR_PER_TICK=1)
}
NBAD() { find "$ST/tproj/.bad" -type f -name 'tproj-TK-77.*.json' 2>/dev/null | wc -l; }

# ============================================================================
# B1. AN HOUR-OLD UNPARSEABLE RECORD: named on the tick line, marked
#     +index-short on this tick, and moved to .bad/ with one line. The valid
#     record beside it is not touched.
# ============================================================================
SETUP 3600
RUN
LASTTICK | grep -qE " bad_records=\[$BADF\]\$" && ok \
  || bad "B1: THE BUG: the tick line must end bad_records=[<path>] (tick: $(LASTTICK))"
case "$(LFIELD reason)" in *+index-short*) ok ;; *) bad "B1: the tick that saw it is still +index-short (tick: $(LASTTICK))" ;; esac
[ ! -e "$BADF" ] && ok || bad "B1: THE BUG: the bad record must leave its old path"
[ "$(NBAD)" = 1 ] && ok || bad "B1: it must be under .bad/ once (found $(NBAD))"
QF=$(find "$ST/tproj/.bad" -type f 2>/dev/null | head -1)
[ "$(cat "$QF" 2>/dev/null)" = "not json at all" ] && ok || bad "B1: the quarantined file keeps its bytes"
[ "$(grep -c 'tproj/tproj-TK-77: unparseable state record quarantined to ' "$LOGF")" = 1 ] && ok \
  || bad "B1: ONE quarantine line (log: $(grep -i quarantin "$LOGF"))"
[ "$(jq -r .outcome "$ST/tproj/tproj-TK-31.json")" = ABANDONED ] && ok || bad "B1: the valid record beside it is untouched"

# ============================================================================
# B2 + B5. THE NEXT TICK IS CLEAN. No bad_records=, no +index-short: the .bad/
#     file is at depth 3, which neither the index nor the rebuilds glob reads,
#     and the candidates are the same.
# ============================================================================
C1=$(LFIELD candidates)
: > "$LOGF"
RUN
grep -q 'bad_records=' <<<"$(LASTTICK)" && bad "B2: tick 2 must not name a record again (tick: $(LASTTICK))" || ok
case "$(LFIELD reason)" in *+index-short*) bad "B2: THE BUG: +index-short must stop after the quarantine (tick: $(LASTTICK))" ;; *) ok ;; esac
[ "$(LFIELD candidates)" = "$C1" ] && ok || bad "B5: the .bad/ file changes no candidate count ($C1 -> $(LFIELD candidates))"
grep -q 'could not be parsed' "$LOGF" && bad "B5: the .bad/ file must not be indexed (log: $(grep 'could not be parsed' "$LOGF"))" || ok

# ============================================================================
# B3. A ONE-MINUTE-OLD BAD RECORD may be mid-write: it is named, never moved.
#     The next tick (same file) does not name it again, and it is still there.
# ============================================================================
SETUP 60
RUN
LASTTICK | grep -qE " bad_records=\[$BADF\]\$" && ok || bad "B3: the young record is named (tick: $(LASTTICK))"
[ -e "$BADF" ] && ok || bad "B3: a record younger than the floor must not be moved"
[ "$(NBAD)" = 0 ] && ok || bad "B3: nothing goes to .bad/"
: > "$LOGF"
RUN
grep -q 'bad_records=' <<<"$(LASTTICK)" && bad "B3: the same bad record is named once per episode, not every tick (tick: $(LASTTICK))" || ok
case "$(LFIELD reason)" in *+index-short*) ok ;; *) bad "B3: it is still short while the record stays (tick: $(LASTTICK))" ;; esac
[ -e "$BADF" ] && ok || bad "B3: still in place on tick 2"

# ============================================================================
# B4. BR_BAD_RECORD_QUARANTINE_MIN=0 names it and never moves it.
# ============================================================================
SETUP 3600
BRENV=(BR_PER_TICK=1 BR_BAD_RECORD_QUARANTINE_MIN=0)
RUN
LASTTICK | grep -q " bad_records=\[$BADF\]" && ok || bad "B4: knob 0 still names it (tick: $(LASTTICK))"
[ -e "$BADF" ] && [ "$(NBAD)" = 0 ] && ok || bad "B4: knob 0 never moves it"

# ============================================================================
# B6. THE MOVE FAILS (.bad is a file, so no dir can be made there): one line,
#     and the record stays where it is.
# ============================================================================
SETUP 3600
printf 'in the way\n' > "$ST/tproj/.bad"
RUN
[ -e "$BADF" ] && ok || bad "B6: a failed move leaves the record in place"
[ "$(grep -c 'tproj/tproj-TK-77: unparseable state record could not be quarantined' "$LOGF")" = 1 ] && ok \
  || bad "B6: a failed move says so in ONE line (log: $(grep -i quarantin "$LOGF"))"
[ "$(cat "$ST/tproj/.bad")" = "in the way" ] && ok || bad "B6: nothing is written over the file in the way"

# ============================================================================
# B7. OBSERVE MODE says WOULD and moves nothing.
# ============================================================================
SETUP 3600
touch "$H/flags/blocked-resolver-observe"
RUN
rm -f "$H/flags/blocked-resolver-observe"
[ -e "$BADF" ] && ok || bad "B7: observe mode moves nothing"
grep -q 'tproj/tproj-TK-77: WOULD quarantine' "$LOGF" && ok || bad "B7: observe mode says WOULD quarantine (log: $(grep -i quarantin "$LOGF"))"

echo "blocked-resolver-bad-record.bh-9029: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
