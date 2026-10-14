#!/bin/bash
# tests/alert-line-wave-cost-health.bh-2314-test.sh — BH-2364, the cost, health
# and orchestration slice of the BH-2314 alert-writer waves: twelve scripts'
# bare `echo … >> ALERTS.log` writes now go through bin/alert-line.sh, which
# notes the alerts row at emit time instead of a minute later on the
# poll-commands re-beat.
#
# Driven, not grepped (D2/D3). Every case runs shipped code in a scratch
# $HARNESS against a stub bin/beat.sh that records each payload:
#   A  the whole bin/cost-rollup.sh, cost_rows read disarmed: the stub gets one
#      kind:"alert" payload whose .line is the exact pre-conversion sentence,
#      ALERTS.log's last line is that .line, and its sent-marker exists.
#      A-fail: a failing beat.sh still gets the line on file, with no marker.
#      A-mut runs a copy with the site put back to a raw append and asserts
#      the stub hears nothing, so A cannot pass on a raw writer.
#   B  pipeline-health's alert() + the per-tick cap: 25 alerts at cap 20 give
#      20 beats, 20 markers and 25 byte-identical lines in call order; cap 30
#      gives 25 beats; with no knob set the cap is 20.
#   C  cost-rollup's new-pair block: write, then mark. An unwritable ALERTS.log
#      leaves no ledger put and no flag; a writable one puts and the line on
#      file equals the stub's .line.
#   D  the ratchet's scanner lists alerts-medic, hub-lease and iron-law-guard
#      as by-design (the ratchet itself runs only in its own suite).
#   E  census: no bare ALERTS.log append left in the nine converted files, the
#      scanner rows for agent-call / pipeline-health / cache-hit-report, and no
#      lane-alert.sh call added.
#
# Run from anywhere: tests/alert-line-wave-cost-health.bh-2314-test.sh (exit 0 = pass)
# No network.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/ratchet-delta.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
sha() { printf %s "$1" | sha1sum | cut -c1-40; }
command -v jq >/dev/null && command -v python3 >/dev/null || { echo "jq/python3 missing — skipping"; exit 0; }
unset HARNESS_SECRET JOBS_URL
export ALERTS_CONF="$T/alerts.conf"; : > "$ALERTS_CONF"
STAMP_RE='^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}Z '

# mktree <dir> — the helper and what it reads, plus a recording stub beat.sh
mktree() {
  local d="$1"
  mkdir -p "$d/bin/lib" "$d/logs" "$d/state" "$d/flags"
  cp "$DIR/bin/alert-line.sh" "$DIR/bin/alert_family.py" "$d/bin/"
  cp "$DIR/bin/lib/alert-state.sh" "$DIR/bin/lib/conf-row.sh" "$d/bin/lib/"
  cat > "$d/bin/beat.sh" <<'EOF'
#!/bin/bash
H="$(cd "$(dirname "$0")/.." && pwd)"
printf '%s\n' "$1" >> "$H/beats.jsonl"
exit 0
EOF
  chmod +x "$d/bin/beat.sh"
}
alert_beats() { jq -c 'select(.kind=="alert")' "$1/beats.jsonl" 2>/dev/null; }

echo "--- A: bin/cost-rollup.sh, cost_rows disarmed, through the helper"
A_TEXT='[cost-rollup] cost_rows is unreadable (or COST_ROWS_FROM_DB / flags/cost-rows-from-db-off disarmed the read), so the rollup did not run: state/cost/ (summary.json, fleet-cost.csv, cost-per-pr.csv) still holds the last good run and every dashboard dollar figure is aging. The reason is in logs/agent-rules.log [cost-rows-read]; check the harness-jobs worker and run bin/cost-rows-push.sh --verify <box>.'
run_rollup() { # run_rollup <tree> <script>
  mkdir -p "$1/bin/lib" "$1/flags"
  cp "$DIR/bin/lib/cost-rows-read.sh" "$1/bin/lib/"
  : > "$1/fleet.conf"; touch "$1/flags/cost-rows-from-db-off"
  cp "$2" "$1/bin/cost-rollup.sh"; chmod +x "$1/bin/cost-rollup.sh"
  ( export HARNESS="$1" COST_ROLLUP_TIMEBOXED=1
    bash "$1/bin/cost-rollup.sh" >"$1/out" 2>"$1/err" ); echo $?
}
A="$T/a"; mktree "$A"
RC=$(run_rollup "$A" "$DIR/bin/cost-rollup.sh")
[ "$RC" = 0 ] && ok || bad "A0: cost-rollup exited $RC: $(tail -3 "$A/err")"
AB=$(alert_beats "$A")
[ "$(printf '%s' "$AB" | grep -c .)" = 1 ] && ok || bad "A1: want exactly one kind:alert payload, got: ${AB:-none}"
AL=$(jq -r '.line' <<<"$AB" 2>/dev/null | head -1)
grep -qE "$STAMP_RE" <<<"$AL" && [ "${AL#* * }" = "$A_TEXT" ] && ok \
  || bad "A2: payload .line is not <stamp> + the pre-conversion text
  got: $AL"
[ "$(tail -n 1 "$A/logs/ALERTS.log" 2>/dev/null)" = "$AL" ] && [ -n "$AL" ] && ok \
  || bad "A3: ALERTS.log's last line is not the beaten line (ALERTS: $(cat "$A/logs/ALERTS.log" 2>/dev/null))"
[ -n "$AL" ] && [ -f "$A/state/alert-line-sent/$(sha "$AL")" ] && ok || bad "A4: no sent-marker for the beaten line"
[ -n "$AL" ] && [ ! -e "/root/harness/state/alert-line-sent/$(sha "$AL")" ] && ok \
  || bad "A5: the line was marked in the real /root/harness, not the scratch tree"
# A-fail: the beat fails (stub exits 1) — the line still lands, unmarked, for the re-beat
AF="$T/afail"; mktree "$AF"
printf '#!/bin/bash\nH="$(cd "$(dirname "$0")/.." && pwd)"\nprintf "%%s\\n" "$1" >> "$H/beats.jsonl"\nexit 1\n' > "$AF/bin/beat.sh"
RC=$(run_rollup "$AF" "$DIR/bin/cost-rollup.sh")
AFL=$(grep -F "$A_TEXT" "$AF/logs/ALERTS.log" 2>/dev/null)
[ "$(grep -c . <<<"$AFL")" = 1 ] && grep -qE "$STAMP_RE" <<<"$AFL" && ok \
  || bad "A6: with beat.sh failing, ALERTS.log must still get the line once (got: ${AFL:-none})"
[ -n "$(alert_beats "$AF")" ] && [ ! -f "$AF/state/alert-line-sent/$(sha "$AFL")" ] && ok \
  || bad "A7: a failed beat must be attempted and leave no sent-marker"
# A-mut: the same site as a raw append goes silent at the stub
AM="$T/amut"; mktree "$AM"
AMHIT=$(python3 - "$DIR/bin/cost-rollup.sh" "$T/rollup-mut.sh" <<'PY'
import sys
s = open(sys.argv[1]).read()
key = "cost_rows is unreadable (or COST_ROWS_FROM_DB"
lines = s.split("\n")
hit = [i for i, l in enumerate(lines) if key in l and "alert-line.sh" in l]
for i in hit:
    l = lines[i]
    ind = l[:len(l) - len(l.lstrip())]
    txt = l[l.index('"[cost-rollup]'):]
    lines[i] = ind + 'echo "$(STAMP) ' + txt[1:] + ' >> "$H/logs/ALERTS.log"'
open(sys.argv[2], "w").write("\n".join(lines))
print(len(hit))
PY
)
[ "$AMHIT" = 1 ] && ok || bad "A-mut: the mutation found '$AMHIT' helper site(s) to revert, want 1"
RC=$(run_rollup "$AM" "$T/rollup-mut.sh")
[ -z "$(alert_beats "$AM")" ] && grep -qF "$A_TEXT" "$AM/logs/ALERTS.log" 2>/dev/null && ok \
  || bad "A-mut: a raw-append copy of the site must write the line and beat nothing (beats: $(alert_beats "$AM"))"

echo "--- B: pipeline-health alert() under the per-tick cap"
awk '/^# >>> alert emit cap/{f=1;next} /^# <<< alert emit cap/{exit} f' "$DIR/bin/pipeline-health.sh" > "$T/cap.sh"
awk '/^alert\(\) \{/{f=1} f{print} f && /^\}/{exit}' "$DIR/bin/pipeline-health.sh" > "$T/alertfn.sh"
[ -s "$T/cap.sh" ] && ok || bad "B0: no '# >>> alert emit cap' block in bin/pipeline-health.sh"
[ -s "$T/alertfn.sh" ] && ok || bad "B0: no alert() in bin/pipeline-health.sh"
fire_b() { # fire_b <tree> <cap> — 25 distinct alert() calls in one tick
  mktree "$1"; echo '{}' > "$1/state/health-alerted.json"
  ( export ALERT_LINE_TICK_MAX="$2"
    H="$1"; unset HARNESS; NOW=$(date +%s)
    DEDUP="$H/state/health-alerted.json"; FIRED="$H/state/fired"; : > "$FIRED"
    STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
    . "$T/cap.sh"; . "$T/alertfn.sh"
    for i in $(seq -w 1 25); do alert 3600 "k:$i" "https://github.com/o/r/pull/$i aging ${i}h — item $i"; done
  ) >/dev/null 2>&1
}
B="$T/b"; fire_b "$B" 20
[ "$(alert_beats "$B" | grep -c .)" = 20 ] && ok || bad "B1: cap 20 must give 20 kind:alert beats, got $(alert_beats "$B" | grep -c .)"
grep -E "$STAMP_RE" "$B/logs/ALERTS.log" 2>/dev/null | cut -d' ' -f3- > "$T/b.got"
for i in $(seq -w 1 25); do echo "[pipeline-health] https://github.com/o/r/pull/$i aging ${i}h — item $i"; done > "$T/b.want"
[ "$(grep -cE "$STAMP_RE" "$B/logs/ALERTS.log" 2>/dev/null)" = 25 ] && cmp -s "$T/b.got" "$T/b.want" && ok \
  || bad "B2: ALERTS.log must hold the 25 lines byte-identical and in call order
$(diff "$T/b.want" "$T/b.got" | head -5)"
[ "$(find "$B/state/alert-line-sent" -type f 2>/dev/null | wc -l)" = 20 ] && ok \
  || bad "B3: want 20 sent-markers, got $(find "$B/state/alert-line-sent" -type f 2>/dev/null | wc -l)"
L21=$(sed -n 21p "$B/logs/ALERTS.log")
[ -n "$L21" ] && [ ! -f "$B/state/alert-line-sent/$(sha "$L21")" ] && ok || bad "B4: the 21st line (past the cap) must carry no marker"
B30="$T/b30"; fire_b "$B30" 30
[ "$(alert_beats "$B30" | grep -c .)" = 25 ] && ok || bad "B5: cap 30 must give 25 kind:alert beats, got $(alert_beats "$B30" | grep -c .)"

# default: no env, empty conf -> the cap is 20
BD="$T/bdef"; ( unset ALERT_LINE_TICK_MAX; mktree "$BD"; echo '{}' > "$BD/state/health-alerted.json"
  H="$BD"; unset HARNESS; NOW=$(date +%s)
  DEDUP="$H/state/health-alerted.json"; FIRED="$H/state/fired"; : > "$FIRED"
  STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
  . "$T/cap.sh"; . "$T/alertfn.sh"
  for i in $(seq -w 1 25); do alert 3600 "k:$i" "item $i"; done ) >/dev/null 2>&1
[ "$(alert_beats "$BD" | grep -c .)" = 20 ] && [ "$(grep -c . "$BD/logs/ALERTS.log")" = 25 ] && ok \
  || bad "B6: with no knob set the cap must be 20 (beats $(alert_beats "$BD" | grep -c .), lines $(grep -c . "$BD/logs/ALERTS.log" 2>/dev/null))"

echo "--- C: cost-rollup new-pair alert, write then mark"
awk '/^# >>> new unpriced pair alert/{f=1;next} /^# <<< new unpriced pair alert/{exit} f' "$DIR/bin/cost-rollup.sh" > "$T/newpair.sh"
[ -s "$T/newpair.sh" ] && ok || bad "C0: no '# >>> new unpriced pair alert' block in bin/cost-rollup.sh"
fire_c() { # fire_c <tree>
  mkdir -p "$1/state/cost"
  jq -nc '{fleet_ledger_unpriced_pairs_24h:[{runner:"openrouter",model:"acme/x-1",calls:2,tokens:900,priceable:false,in_catalog:false,no_usage:0}]}' \
    > "$1/state/cost/summary.json"
  : > "$1/puts"
  H="$1" CD="$1/state/cost" bash -c '
    set -uo pipefail; unset HARNESS
    STAMP() { date -u "+%Y-%m-%d %H:%M:%SZ"; }
    job_ledger_get() { return 2; }
    job_ledger_put() { printf "%s\t%s\n" "$1" "$2" >> "$H/puts"; return 0; }
    . "$0"' "$T/newpair.sh" >/dev/null 2>&1
}
C1="$T/c1"; mktree "$C1"; mkdir -p "$C1/logs/ALERTS.log"
fire_c "$C1"
[ ! -s "$C1/puts" ] && [ -z "$(ls "$C1/flags" 2>/dev/null)" ] && ok \
  || bad "C1: an unwritable ALERTS.log must leave no ledger put and no flag (puts: $(cat "$C1/puts"); flags: $(ls "$C1/flags"))"
C2="$T/c2"; mktree "$C2"; fire_c "$C2"
[ "$(cut -f2 "$C2/puts" 2>/dev/null)" = "openrouter|acme/x-1" ] && ls "$C2/flags"/alerted-unpriced-new-* >/dev/null 2>&1 && ok \
  || bad "C2: a written line must mark the pair and set the flag (puts: $(cat "$C2/puts"))"
CL=$(alert_beats "$C2" | jq -r '.line' 2>/dev/null)
grep -q 'NEW UNPRICED PAIR(S): openrouter/acme/x-1' <<<"$CL" && [ "$(tail -n 1 "$C2/logs/ALERTS.log")" = "$CL" ] && ok \
  || bad "C3: the stub's .line and ALERTS.log's line must be the same NEW UNPRICED PAIR line
  beat: $CL
  file: $(tail -n 1 "$C2/logs/ALERTS.log" 2>/dev/null)"

echo "--- E: census over the twelve files"
for f in reopen-metrics orchestrate cost-rollup healthcheck cost-reconcile context-gate agent-call pipeline-health cache-hit-report; do
  # a site whose line above is the overflow reason comment is the one sanctioned raw write
  n=$(awk '/>>[[:space:]]*"?[^ ]*ALERTS\.log/ && prev !~ /# alert-writer overflow/ {n++} {prev=$0} END{print n+0}' "$DIR/bin/$f.sh")
  [ "$n" = 0 ] && ok || bad "E1: bin/$f.sh still has $n bare ALERTS.log append(s)"
done
for f in pipeline-health cache-hit-report; do
  grep -qE '^\s*# alert-writer overflow \(BH-2364\)' "$DIR/bin/$f.sh" && ok || bad "E2: bin/$f.sh has no overflow reason comment"
done
python3 - "$DIR/tests/alert-writers-ratchet.bh-2314-test.sh" "$T/scan.py" <<'PY'
import sys
s = open(sys.argv[1]).read()
a = s.index("cat > \"$T/scan.py\" <<'PY'\n") + len("cat > \"$T/scan.py\" <<'PY'\n")
open(sys.argv[2], "w").write(s[a:s.index("\nPY\n", a)] + "\n")
PY
python3 "$T/scan.py" "$DIR/bin" > "$T/rows.tsv" 2>/dev/null; SRC=$?

echo "--- D: by-design files, as the ratchet's scanner reads them"
# The ratchet itself runs in tests/alert-writers-ratchet.bh-2314-test.sh and
# nowhere else: re-running it here doubled its reds (all 10 of this suite's
# reds in the 2026-09-25..28 batches were that re-run). This suite's own claim
# is only that the three files read as by-design, so D reads the exempt column
# of the ratchet's own scanner, extracted above rather than retyped.
[ "$SRC" = 0 ] && [ -s "$T/rows.tsv" ] && ok || bad "D1: the ratchet's scanner failed or read nothing (rc=$SRC)"
EX=$(awk -F'\t' '$3 == 1 { printf "%s ", $1 }' "$T/rows.tsv")
for f in alerts-medic.sh hub-lease.sh iron-law-guard.sh; do
  grep -qE "(^| )$f( |$)" <<<"$EX" && ok || bad "D2: $f is not listed by-design: $EX"
done
row() { awk -F'\t' -v f="$1" '$1==f{print $2}' "$T/rows.tsv"; }
[ "$(row agent-call.sh)" = 22 ] && ok || bad "E3: agent-call.sh scanner row is '$(row agent-call.sh)', want 22"
[ "$(row pipeline-health.sh)" = 1 ] && ok || bad "E3: pipeline-health.sh scanner row is '$(row pipeline-health.sh)', want 1"
[ "$(row cache-hit-report.sh)" = 1 ] && ok || bad "E3: cache-hit-report.sh scanner row is '$(row cache-hit-report.sh)', want 1"
for f in reopen-metrics orchestrate cost-rollup healthcheck cost-reconcile context-gate; do
  [ "$(row "$f.sh")" = 0 ] && ok || bad "E3: $f.sh scanner row is '$(row "$f.sh")', want 0"
done
# E4 judges THIS diff (tests/lib/ratchet-delta.sh): against the merge-base with
# main, not origin/main's tip, so a lane-alert.sh call main dropped after this
# branch forked is not read as one this branch added. No base is red.
if E4_BASE=$(rd_base "$DIR"); then
  for f in reopen-metrics orchestrate cost-rollup healthcheck pipeline-health cost-reconcile context-gate agent-call cache-hit-report; do
    was=$(git -C "$DIR" show "$E4_BASE:bin/$f.sh" 2>/dev/null | grep -c 'lane-alert\.sh')
    # BH-3941: the review-paid-unchanged warn/resolve is a lane-alert by spec
    # (a warn digest and a resolve, which alert-line.sh has no form for). Only
    # a call naming that id is exempt; any other new call is still red.
    now=$(grep 'lane-alert\.sh' "$DIR/bin/$f.sh" | grep -vc -- '--id review-paid-unchanged ')
    [ "$now" -le "$was" ] && ok || bad "E4: bin/$f.sh gained a lane-alert.sh call ($was -> $now); keep kind:alert"
  done
else
  bad "E4: $E4_BASE"
fi

echo "alert-line-wave-cost-health: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
