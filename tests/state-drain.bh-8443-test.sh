#!/bin/bash
# tests/state-drain.bh-8443-test.sh — BH-8443 (C1 of #4159): the box lane that
# archives, then deletes, drained top-level state/ entries, and its --report.
#
# The shipped bin/state-drain.sh is installed with its source closure into a
# scratch harness ($T/h) and DRIVEN against a fixture state dir and archive dir
# per case (the STATE_DRAIN_* seams), a fixed clock (STATE_DRAIN_NOW), a
# fixture crontab file, the REAL catalog/state-paths.json and the rendered lane
# registry. The corpus the lane greps is that scratch harness's bin/ and
# catalog/: the real closure, the real alert-state.sh and rt/gate.sh (the live
# function-built and dynamic writers), the real lane-reprobe.sh and
# sweep-stale-builds.sh, plus one fixture file with the near-miss strings. A
# fake jobs-client.sh records job_ledger_put and a fake lane-alert.sh records
# its argv: 0 network calls. What is proved:
#   D1-D16  the decision rule, one fixture entry per row of the plan's table;
#   X1-X8   the exit paths: real drain (archive round-trip), dry-run default,
#           archive failure (X3 no write, X3b no read-back), refusals, invalid knobs, the per-run cap, a held
#           lock, archive retention; U1 usage;
#   R1-R2   --report and the unallowlisted_files field;
#   RT1     the summary log line and the ledger detail agree;
#   G1      under HARNESS_TEST_SANDBOX with no STATE_DRAIN_STATE_DIR the run
#           skips and the harness's own state/ is untouched;
#   N1      the live STATE-STORES families are never drained;
#   W1      registry and cron wiring.
# Run from anywhere: tests/state-drain.bh-8443-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/rendered.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
unset STATE_DRAIN_DRY_RUN STATE_DRAIN_MIN_IDLE_DAYS STATE_DRAIN_ARCHIVE_KEEP_DAYS STATE_DRAIN_MAX_PER_RUN \
      STATE_DRAIN_SCAN_TIMEOUT_S STATE_DRAIN_STATE_DIR STATE_DRAIN_ARCHIVE_DIR STATE_DRAIN_CRONTAB_FILE \
      STATE_DRAIN_NOW 2>/dev/null || true
HOST=$(hostname)

# ── the scratch harness ──────────────────────────────────────────────────────
H="$T/h"
scratch_install_closure bin/state-drain.sh "$H" >/dev/null \
  || bad "cannot install bin/state-drain.sh's closure"
# the live writers whose names the lane must see in the corpus (D9, D10, D15, D16b)
for f in bin/lib/alert-state.sh bin/lib/rt/gate.sh bin/lane-reprobe.sh bin/sweep-stale-builds.sh; do
  mkdir -p "$H/$(dirname "$f")"; cp "$DIR/$f" "$H/$f" || bad "cannot copy $f into the corpus"
done
mkdir -p "$H/logs" "$H/flags" "$H/locks" "$H/state" "$H/catalog" "$H/env"
cp "$(rendered_registry)" "$H/catalog/lanes.json"
cp "$DIR/catalog/state-paths.json" "$H/catalog/state-paths.json"
cat > "$H/bin/jobs-client.sh" <<'SH'
#!/bin/bash
# fixture jobs client: records job_ledger_put, 0 network calls
job_ledger_put() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >> "$SD_LEDGER"; }
SH
cat > "$H/bin/lane-alert.sh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$SD_ALERTS"
SH
chmod +x "$H/bin/lane-alert.sh"
# the near-miss strings: a sibling name, a superstring, a mktemp template
cat > "$H/bin/zq-fixture-corpus.sh" <<'SH'
#!/bin/bash
# fixture corpus for tests/state-drain.bh-8443-test.sh
x="$H/state/zq-retired-other"
y="zqxlongername"
SH
CRONTAB="$T/crontab"
printf '%s\n' '17 3 * * * /root/harness/bin/x.sh > /root/harness/state/zq-cronlane/out 2>&1' > "$CRONTAB"

NOW=1790000000
DAY=86400
OLD=$((NOW - 40 * DAY))
ANCIENT=$((NOW - 400 * DAY))
export SD_LEDGER="$T/ledger.tsv" SD_ALERTS="$T/alerts.log"
LOG="$H/logs/state-drain.log"

# Fixture sanity: a name a DRAIN case needs must not be in the corpus, or that
# case proves nothing.
for n in zq-oldlane zq-stale-probe zq-retired-thing zq-ghost zq-capdir; do
  if grep -rqaF -- "$n" "$H/bin" "$H/catalog" "$CRONTAB" 2>/dev/null; then
    bad "fixture: '$n' is in the corpus, so its drain case is vacuous"
  fi
done

age() { find "$1" -exec touch -h -d "@$2" {} + 2>/dev/null; }
# mk <state> <name> [epoch] — a dir with 3 files, every mtime at epoch (default OLD)
mk() {
  mkdir -p "$1/$2/sub"
  echo a > "$1/$2/a"; echo b > "$1/$2/b"; echo c > "$1/$2/sub/c"
  age "$1/$2" "${3:-$OLD}"
}
# mkf <state> <name> [epoch] — a file
mkf() { echo x > "$1/$2"; touch -h -d "@${3:-$OLD}" "$1/$2"; }
# newcase <id> — a fresh state dir and archive dir for this case; clears the
# log, ledger and alert records so no case reads another's
newcase() {
  S="$T/cases/$1/state"; A="$T/cases/$1/archive"
  scratch_rm "$T/cases/$1"; mkdir -p "$S" "$A"
  rm -f "$LOG" "$SD_LEDGER" "$SD_ALERTS"
}
# run [VAR=val ...] [-- args] — drive the shipped script against $S/$A
run() {
  local -a envs=() args=()
  while [ $# -gt 0 ]; do
    case "$1" in --) shift; args=("$@"); break ;; *) envs+=("$1"); shift ;; esac
  done
  local rc
  timeout 120 env HARNESS_ROOT="$H" HARNESS="$H" HOME="$T" HARNESS_TEST_SANDBOX=1 \
      STATE_DRAIN_STATE_DIR="$S" STATE_DRAIN_ARCHIVE_DIR="$A" STATE_DRAIN_CRONTAB_FILE="$CRONTAB" \
      STATE_DRAIN_NOW="$NOW" "${envs[@]}" bash "$H/bin/state-drain.sh" "${args[@]}"
  rc=$?
  [ "$rc" = 124 ] && bad "a run of bin/state-drain.sh did not finish in 120 s (${envs[*]} ${args[*]})" >&2
  return "$rc"
}
summary() { grep -E ' run dry=[01] ' "$LOG" 2>/dev/null; }
field() { summary | tail -1 | grep -oE "(^| )$1=[^ ]*" | cut -d= -f2; }
# decision <name> — the decision the last --dry-run printed for <name>
decision() { awk -F'\t' -v n="$1" '$2==n{print $1}' "$T/out"; }
want() { # want <case> <name> <decision>
  local got; got=$(decision "$2")
  [ "$got" = "$3" ] && ok || bad "$1 $2: want decision '$3', got '$got'"
}

# ══ D1-D16 the decision rule (one dry run over every fixture) ════════════════
newcase d
mk  "$S" zq-oldlane                                   # D1
mkf "$S" zq-stale-probe.out                           # D2
mkf "$S" zq-retired-thing.dat                         # D3
mkf "$S" zq-retired-thing.json                        # D3b
mkdir -p "$S/zq-ghost"; age "$S/zq-ghost" "$OLD"      # D4
mk  "$S" gh-etag "$ANCIENT"                           # D5
mkf "$S" box-id "$ANCIENT"                            # D6
mk  "$S" gh-policy-cache "$ANCIENT"                   # D7
mk  "$S" deploy-queue "$ANCIENT"                      # D8
mk  "$S" blocked-resolver "$ANCIENT"                  # D8c
mk  "$S" alerts "$ANCIENT"                            # D9
mkf "$S" zq-proj.gate-meta "$ANCIENT"                 # D10
mk  "$S" zq-cronlane "$ANCIENT"                       # D11
mk  "$S" zq-oldlane-fresh-inside                      # D12
touch -d "@$((NOW - 2 * DAY))" "$S/zq-oldlane-fresh-inside/sub/c"
mk  "$S" zq-oldlane-edge $((NOW - 30 * DAY + 1))      # D13
mkdir -p "$T/outside"; ln -s "$T/outside" "$S/zq-link"; touch -h -d "@$ANCIENT" "$S/zq-link"   # D14
mkf "$S" claude-auth-down.txt.tmp.Xy12Ab "$ANCIENT"   # D15
mkf "$S" .sweep-live.Ab12Cd "$ANCIENT"                # D16b
mkf "$S" zqx "$ANCIENT"                               # D16
mkf "$S" settings-cache.json.tmp "$ANCIENT"           # D5b (a dot sibling of a cache path)
mk  "$S" merge-queue.lock "$ANCIENT"                  # D8b (a dot sibling of a rows path)
run -- --dry-run > "$T/out" 2>"$T/err"; RC=$?
[ "$RC" = 0 ] && ok || bad "D rc must be 0 (got $RC; $(cat "$T/err"))"
want D1  zq-oldlane                     drain
want D2  zq-stale-probe.out             drain
want D3  zq-retired-thing.dat           drain
want D3b zq-retired-thing.json          referenced:.json
want D4  zq-ghost                       drain
want D5  gh-etag                        allowlisted
want D5b settings-cache.json.tmp        allowlisted
want D6  box-id                         allowlisted
want D7  gh-policy-cache                allowlisted
want D8  deploy-queue                   catalog
# not a catalog row: the lane keeps it because live code names it
want D8c blocked-resolver               referenced:blocked-resolver
want D8b merge-queue.lock               catalog
want D9  alerts                         referenced:alerts
want D10 zq-proj.gate-meta              referenced:.gate-meta
want D11 zq-cronlane                    referenced:zq-cronlane
want D12 zq-oldlane-fresh-inside        fresh
want D13 zq-oldlane-edge                fresh
want D14 zq-link                        link
want D15 claude-auth-down.txt.tmp.Xy12Ab referenced:claude-auth-down.txt
want D16b .sweep-live.Ab12Cd            referenced:.sweep-live
want D16 zqx                            referenced:zqx
# the dry run drained nothing and says what it would drain
for n in zq-oldlane zq-stale-probe.out zq-retired-thing.dat zq-ghost; do
  [ -e "$S/$n" ] && ok || bad "D dry run must not delete $n"
  grep -qE " would-drain $n [0-9]+ KB idle_days=40$" "$LOG" && ok || bad "D a 'would-drain $n <kb> KB idle_days=40' log line ($(grep would-drain "$LOG"))"
done
for kv in dry=1 would=4 drained=0 failed=0 allowlisted=4 catalog=2 link=1 fresh=2; do
  [ "$(field "${kv%%=*}")" = "${kv#*=}" ] && ok || bad "D summary must carry $kv ($(summary))"
done
[ -z "$(find "$A" -mindepth 1 -print -quit)" ] && ok || bad "D a dry run must archive nothing ($(find "$A" -mindepth 1))"

# ══ X1 a real run drains, archives first, and the archive round-trips ═══════
newcase x1
mk  "$S" zq-oldlane
mkdir -p "$S/zq-ghost"; age "$S/zq-ghost" "$OLD"
mk  "$S" gh-etag "$ANCIENT"
cp -a "$S/zq-oldlane" "$T/cases/x1/orig-oldlane"
run STATE_DRAIN_DRY_RUN=0 > "$T/out" 2>&1; RC=$?
[ "$RC" = 0 ] && ok || bad "X1 rc must be 0 (got $RC)"
[ ! -e "$S/zq-oldlane" ] && [ ! -e "$S/zq-ghost" ] && ok || bad "X1 zq-oldlane and zq-ghost must be removed"
[ -d "$S/gh-etag" ] && ok || bad "X1 gh-etag (allowlisted) must stay"
STAMP=$(date -u -d "@$NOW" +%Y%m%dT%H%MZ)
ARC="$A/$STAMP/zq-oldlane.tgz"
[ -s "$ARC" ] && tar -tzf "$ARC" >/dev/null 2>&1 && ok || bad "X1 a readable archive $ARC ($(find "$A"))"
[ -s "$A/$STAMP/zq-ghost.tgz" ] && ok || bad "X1 an archive for the empty dir zq-ghost"
mkdir -p "$T/cases/x1/x"; tar -xzf "$ARC" -C "$T/cases/x1/x" 2>/dev/null
diff -r "$T/cases/x1/orig-oldlane" "$T/cases/x1/x/zq-oldlane" >/dev/null 2>&1 && ok \
  || bad "X1 the extracted archive must equal the original tree"
grep -qE " drained zq-oldlane [0-9]+ KB idle_days=40 archive=$ARC$" "$LOG" && ok || bad "X1 a 'drained' log line with the archive path ($(cat "$LOG"))"
for kv in dry=0 drained=2 would=0 failed=0 left=0; do
  [ "$(field "${kv%%=*}")" = "${kv#*=}" ] && ok || bad "X1 summary must carry $kv ($(summary))"
done
row=$(cat "$SD_LEDGER" 2>/dev/null)
[ "$(printf '%s\n' "$row" | grep -c .)" = 1 ] && ok || bad "X1 exactly one ledger row ($row)"
[ "$(cut -f1 <<<"$row")" = state_drain ] && [ "$(cut -f2 <<<"$row")" = "state-drain $HOST" ] && [ "$(cut -f3 <<<"$row")" = ok ] && ok \
  || bad "X1 ledger row: kind state_drain, key 'state-drain $HOST', status ok ($row)"
[ "$(cut -f4 <<<"$row" | jq -r '.drained')" = 2 ] && ok || bad "X1 ledger detail drained=2 ($row)"
grep -q -- "--resolve --id state-drain:failed-$HOST" "$SD_ALERTS" 2>/dev/null && ok || bad "X1 a good real run resolves state-drain:failed-$HOST ($(cat "$SD_ALERTS" 2>/dev/null))"
grep -q -- '--severity' "$SD_ALERTS" 2>/dev/null && bad "X1 a good run raises no warn ($(cat "$SD_ALERTS"))" || ok

# ══ X2 the default is a dry run: nothing deleted, row dry:1, no warn raised ═
newcase x2
mk "$S" zq-oldlane
run > "$T/out" 2>&1; RC=$?
[ "$RC" = 0 ] && ok || bad "X2 rc must be 0 (got $RC)"
[ -d "$S/zq-oldlane" ] && ok || bad "X2 the default run must delete nothing"
[ -z "$(find "$A" -mindepth 1 -print -quit)" ] && ok || bad "X2 the default run must archive nothing"
[ "$(field dry)" = 1 ] && [ "$(field would)" = 1 ] && ok || bad "X2 summary dry=1 would=1 ($(summary))"
[ "$(cut -f4 "$SD_LEDGER" 2>/dev/null | jq -r '.dry')" = 1 ] && [ "$(cut -f3 "$SD_LEDGER")" = ok ] && ok \
  || bad "X2 ledger row ok with dry:1 ($(cat "$SD_LEDGER" 2>/dev/null))"
grep -q -- '--severity' "$SD_ALERTS" 2>/dev/null && bad "X2 a dry run raises no warn ($(cat "$SD_ALERTS"))" || ok
grep -q "state-drain:failed" "$SD_ALERTS" 2>/dev/null && bad "X2 a dry run never touches the failed warn" || ok

# ══ X3 the archive cannot be written: the entry is kept, failed=1, one warn ═
newcase x3
mk "$S" zq-oldlane
: > "$T/cases/x3/notadir"
run STATE_DRAIN_DRY_RUN=0 STATE_DRAIN_ARCHIVE_DIR="$T/cases/x3/notadir/arch" > "$T/out" 2>&1; RC=$?
[ "$RC" = 0 ] && ok || bad "X3 rc must be 0 (got $RC)"
[ -d "$S/zq-oldlane" ] && [ -f "$S/zq-oldlane/sub/c" ] && ok || bad "X3 an entry whose archive failed must be kept whole"
grep -q " archive-failed zq-oldlane" "$LOG" && ok || bad "X3 an 'archive-failed zq-oldlane' line ($(cat "$LOG"))"
[ "$(field failed)" = 1 ] && [ "$(field drained)" = 0 ] && ok || bad "X3 summary failed=1 drained=0 ($(summary))"
[ "$(cut -f3 "$SD_LEDGER" 2>/dev/null)" = partial ] && ok || bad "X3 ledger status partial ($(cat "$SD_LEDGER" 2>/dev/null))"
[ "$(grep -c -- "--id state-drain:failed-$HOST --severity warn" "$SD_ALERTS" 2>/dev/null)" = 1 ] && ok \
  || bad "X3 exactly one warn state-drain:failed-$HOST ($(cat "$SD_ALERTS" 2>/dev/null))"

# ══ X3b the archive is written but does not read back: the entry is kept ═══
newcase x3b
mk "$S" zq-oldlane
mkdir -p "$T/fakebin"
REAL_TAR=$(command -v tar)
cat > "$T/fakebin/tar" <<SH
#!/bin/bash
case "\$1" in -tzf) exit 1 ;; esac
exec "$REAL_TAR" "\$@"
SH
chmod +x "$T/fakebin/tar"
run PATH="$T/fakebin:$PATH" STATE_DRAIN_DRY_RUN=0 > "$T/out" 2>&1; RC=$?
[ "$RC" = 0 ] && ok || bad "X3b rc must be 0 (got $RC)"
[ -f "$S/zq-oldlane/sub/c" ] && ok || bad "X3b an entry whose archive does not read back must be kept whole"
grep -q " archive-failed zq-oldlane" "$LOG" && [ "$(field drained)" = 0 ] && ok || bad "X3b archive-failed and drained=0 ($(cat "$LOG"))"

# ══ X4 refusals: catalog missing / invalid, bin/ empty ═══════════════════════
# refused_case <id> <harness root> <why regex> [no-client] — no-client: the
# judged harness has no bin/, so no jobs client or lane-alert to record
refused_case() {
  local id="$1" root="$2" why="$3" nc="${4:-}" rc
  newcase "$id"
  mk "$S" zq-oldlane
  run HARNESS_ROOT="$root" HARNESS="$root" STATE_DRAIN_DRY_RUN=0 > "$T/out" 2>&1; rc=$?
  [ "$rc" = 0 ] && ok || bad "$id rc must be 0 (got $rc)"
  [ -d "$S/zq-oldlane" ] && ok || bad "$id a refused run must delete nothing"
  grep -qE " refused \($why" "$root/logs/state-drain.log" 2>/dev/null && ok \
    || bad "$id a 'refused ($why' log line ($(cat "$root/logs/state-drain.log" 2>/dev/null))"
  [ "$nc" = no-client ] && return 0
  [ "$(cut -f3 "$SD_LEDGER" 2>/dev/null)" = refused ] && ok || bad "$id ledger status refused ($(cat "$SD_LEDGER" 2>/dev/null))"
  [ "$(grep -c -- "--id state-drain:refused-$HOST --severity warn" "$SD_ALERTS" 2>/dev/null)" = 1 ] && ok \
    || bad "$id exactly one warn state-drain:refused-$HOST ($(cat "$SD_ALERTS" 2>/dev/null))"
}
mkroot() { scratch_rm "$T/roots/$1"; mkdir -p "$T/roots"; cp -a "$H" "$T/roots/$1"; printf '%s' "$T/roots/$1"; }
R=$(mkroot x4);  rm -f "$R/catalog/state-paths.json"
refused_case X4  "$R" 'catalog'
R=$(mkroot x4b); echo '{not json' > "$R/catalog/state-paths.json"
refused_case X4b "$R" 'catalog'
R=$(mkroot x4c); scratch_rm "$R/bin"; mkdir -p "$R/bin"
# the script itself runs from $H; the harness it judges has an empty bin/
refused_case X4c "$R" 'bin' no-client

# ══ X5 an invalid knob refuses the run ══════════════════════════════════════
for kv in STATE_DRAIN_MIN_IDLE_DAYS=3 STATE_DRAIN_DRY_RUN=2 STATE_DRAIN_MAX_PER_RUN=abc STATE_DRAIN_ARCHIVE_KEEP_DAYS=1 STATE_DRAIN_SCAN_TIMEOUT_S=0; do
  newcase "x5-${kv%%=*}"
  mk "$S" zq-oldlane
  if [ "${kv%%=*}" = STATE_DRAIN_DRY_RUN ]; then run "$kv" > "$T/out" 2>&1; else run STATE_DRAIN_DRY_RUN=0 "$kv" > "$T/out" 2>&1; fi
  RC=$?
  [ "$RC" = 0 ] && ok || bad "X5 $kv rc must be 0 (got $RC)"
  [ -d "$S/zq-oldlane" ] && ok || bad "X5 $kv must delete nothing"
  grep -qE " refused \(${kv%%=*} invalid" "$LOG" && ok || bad "X5 $kv: a 'refused (${kv%%=*} invalid' line ($(cat "$LOG" 2>/dev/null))"
  [ "$(cut -f3 "$SD_LEDGER" 2>/dev/null)" = refused ] && ok || bad "X5 $kv ledger status refused"
done

# ══ X6 the per-run cap ══════════════════════════════════════════════════════
newcase x6
for i in 1 2 3 4 5; do mk "$S" "zq-capdir$i"; done
run STATE_DRAIN_DRY_RUN=0 STATE_DRAIN_MAX_PER_RUN=2 > "$T/out" 2>&1; RC=$?
[ "$RC" = 0 ] && ok || bad "X6 rc must be 0 (got $RC)"
[ "$(field drained)" = 2 ] && [ "$(field left)" = 3 ] && ok || bad "X6 summary drained=2 left=3 ($(summary))"
[ ! -e "$S/zq-capdir1" ] && [ ! -e "$S/zq-capdir2" ] && ok || bad "X6 the first two in name order are drained"
[ -d "$S/zq-capdir3" ] && [ -d "$S/zq-capdir4" ] && [ -d "$S/zq-capdir5" ] && ok || bad "X6 the other three stay"

# ══ X7 a held lock: no run ══════════════════════════════════════════════════
newcase x7
mk "$S" zq-oldlane
exec 8>"$H/locks/state-drain.lock"
flock -n 8 || bad "X7 fixture: the test cannot take the lock"
run STATE_DRAIN_DRY_RUN=0 > "$T/out" 2>&1; RC=$?
exec 8>&-
[ "$RC" = 0 ] && ok || bad "X7 rc must be 0 (got $RC)"
[ -d "$S/zq-oldlane" ] && ok || bad "X7 a run behind a held lock must delete nothing"
[ ! -s "$LOG" ] && ok || bad "X7 a run behind a held lock writes no log line ($(cat "$LOG"))"
[ ! -s "$SD_LEDGER" ] && ok || bad "X7 a run behind a held lock writes no row"

# ══ X8 archive retention ════════════════════════════════════════════════════
x8_seed() {
  OLDST=$(date -u -d "@$((NOW - 100 * DAY))" +%Y%m%dT%H%MZ); NEWST=$(date -u -d "@$((NOW - 10 * DAY))" +%Y%m%dT%H%MZ)
  mkdir -p "$A/$OLDST" "$A/$NEWST" "$A/keepme"
  echo x > "$A/$OLDST/a.tgz"; echo y > "$A/$NEWST/b.tgz"
}
newcase x8
x8_seed
run STATE_DRAIN_DRY_RUN=0 > "$T/out" 2>&1
[ ! -e "$A/$OLDST" ] && ok || bad "X8 a 100-day-old archive run dir is pruned (keep 90)"
[ -d "$A/$NEWST" ] && [ -d "$A/keepme" ] && ok || bad "X8 a 10-day-old run dir and a non-stamp dir stay"
grep -q " archive-pruned $A/$OLDST$" "$LOG" && ok || bad "X8 an 'archive-pruned' line ($(cat "$LOG"))"
[ "$(field archives_pruned)" = 1 ] && ok || bad "X8 summary archives_pruned=1 ($(summary))"
newcase x8d
x8_seed
run > "$T/out" 2>&1
[ -d "$A/$OLDST" ] && ok || bad "X8 a dry run prunes no archive"

# ══ U1 usage ════════════════════════════════════════════════════════════════
newcase u1
run -- --bogus > "$T/out" 2>&1; RC=$?
[ "$RC" = 2 ] && ok || bad "U1 an unknown argument is rc 2 (got $RC)"

# ══ R1-R2 the report ════════════════════════════════════════════════════════
newcase r1
mkdir -p "$S/gh-etag" "$S/merge-queue"
echo a > "$S/gh-etag/a"; echo b > "$S/box-id"; echo c > "$S/merge-queue/x"; echo d > "$S/foo.txt"
run -- --report > "$T/out" 2>"$T/err"; RC=$?
[ "$RC" = 0 ] && ok || bad "R1 rc must be 0 (got $RC)"
[ "$(sort "$T/out" | tr '\n' ' ')" = "foo.txt merge-queue/x " ] && ok || bad "R1 the report lists exactly foo.txt and merge-queue/x ($(cat "$T/out"))"
grep -q '^unallowlisted_files=2 segments=2$' "$T/err" && ok || bad "R1 stderr 'unallowlisted_files=2 segments=2' ($(cat "$T/err"))"
[ -d "$S/merge-queue" ] && [ ! -s "$SD_LEDGER" ] && [ ! -s "$LOG" ] && ok || bad "R1 the report changes nothing and writes no row or log"
newcase r2
mkdir -p "$S/gh-etag"; echo a > "$S/gh-etag/a"; echo b > "$S/box-id"; echo c > "$S/settings-cache.json.tmp"
run -- --report > "$T/out" 2>"$T/err"
[ ! -s "$T/out" ] && grep -q '^unallowlisted_files=0 segments=0$' "$T/err" && ok || bad "R2 an allowlisted-only dir reports nothing and 0 ($(cat "$T/out" "$T/err"))"

# ══ RT1 the summary line and the ledger detail agree ═══════════════════════
newcase rt1
mk "$S" zq-oldlane; mk "$S" gh-etag "$ANCIENT"; mk "$S" claims "$ANCIENT"; echo z > "$S/claims/z"
run STATE_DRAIN_DRY_RUN=0 > "$T/out" 2>&1
det=$(cut -f4 "$SD_LEDGER" 2>/dev/null)
n=0
for kv in $(summary | tail -1 | grep -oE '[a-z_]+=[0-9]+'); do
  k="${kv%%=*}"; v="${kv#*=}"
  [ "$(jq -r --arg k "$k" '.[$k] | tostring' <<<"$det" 2>/dev/null)" = "$v" ] && ok || bad "RT1 $k: log $v, ledger $(jq -c --arg k "$k" '.[$k]' <<<"$det" 2>/dev/null)"
  n=$((n + 1))
done
[ "$n" -ge 12 ] && ok || bad "RT1 the summary carries at least 12 counts (got $n: $(summary))"
[ "$(field unallowlisted_files)" -ge 1 ] 2>/dev/null && ok || bad "RT1 unallowlisted_files counts the claims file ($(summary))"

# ══ G1 the sandbox guard ════════════════════════════════════════════════════
newcase g1
mk "$H/state" zq-oldlane
timeout 60 env HARNESS_ROOT="$H" HARNESS="$H" HOME="$T" HARNESS_TEST_SANDBOX=1 STATE_DRAIN_ARCHIVE_DIR="$A" \
  STATE_DRAIN_CRONTAB_FILE="$CRONTAB" STATE_DRAIN_NOW="$NOW" STATE_DRAIN_DRY_RUN=0 bash "$H/bin/state-drain.sh" > "$T/out" 2>&1; RC=$?
[ "$RC" = 0 ] && ok || bad "G1 rc must be 0 (got $RC)"
[ -d "$H/state/zq-oldlane" ] && ok || bad "G1 the harness's own state/ must be untouched under the sandbox"
grep -q ' skipped (STATE_DRAIN_STATE_DIR unset under HARNESS_TEST_SANDBOX)' "$LOG" && ok || bad "G1 a 'skipped' log line ($(cat "$LOG" 2>/dev/null))"
scratch_rm "$H/state/zq-oldlane"

# ══ N1 the live families of docs/STATE-STORES.md are never drained ═════════
newcase n1
FAMS="blocked-resolver fly-pool cost build-queue main-red merge-queue build-notes merge-conductor pool review-autopilot remote-results daily-digest gh-budget pr-owners deploy-queue claims alerts"
for f in $FAMS; do mk "$S" "$f" "$ANCIENT"; done
run STATE_DRAIN_DRY_RUN=0 > "$T/out" 2>&1
for f in $FAMS; do [ -d "$S/$f" ] && ok || bad "N1 the live family $f must never be drained ($(decision "$f"))"; done
[ "$(field drained)" = 0 ] && ok || bad "N1 drained=0 ($(summary))"

# ══ W1 registry and cron wiring ═════════════════════════════════════════════
REG=$(rendered_registry)
row=$(jq -c '.lanes[] | select(.id == "state-drain")' "$REG" 2>/dev/null | head -1)
[ -n "$row" ] && ok || bad "W1 the registry has a state-drain lane"
[ "$(jq -r '.script' <<<"$row" 2>/dev/null)" = bin/state-drain.sh ] && ok || bad "W1 script bin/state-drain.sh"
[ "$(jq -r '.boxes | sort | join(",")' <<<"$row" 2>/dev/null)" = "$(jq -r '.boxes | sort | join(",")' "$DIR/catalog/lanes.d/tmp-sweep.json")" ] && ok \
  || bad "W1 the lane runs on the same boxes as tmp-sweep"
[ "$(jq -r '.knobs[] | select(.env=="STATE_DRAIN_DRY_RUN") | .default' <<<"$row" 2>/dev/null)" = 1 ] && ok || bad "W1 STATE_DRAIN_DRY_RUN defaults to 1"
for s in STATE_DRAIN_STATE_DIR STATE_DRAIN_ARCHIVE_DIR STATE_DRAIN_CRONTAB_FILE STATE_DRAIN_NOW; do
  [ "$(jq -r --arg s "$s" '.knobs[] | select(.env==$s) | .settable' <<<"$row" 2>/dev/null)" = false ] && ok || bad "W1 $s is a seam, not settable"
done
for box in hub small; do
  grep -q '/root/harness/bin/state-drain.sh' "$(rendered_cron "$box")" && ok || bad "W1 cron for $box runs bin/state-drain.sh"
done

echo "state-drain: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
