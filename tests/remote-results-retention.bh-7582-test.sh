#!/bin/bash
# tests/remote-results-retention.bh-7582-test.sh — BH-7582. The REAL
# bin/remote-results-retention.sh, installed with its closure into a scratch
# HARNESS, with a stubbed jobs client (_jobs_req answers from per-key fixture
# files; job_ledger_put records each call and answers rc from a file) and a
# stubbed lane gate (lane_env_apply exports a settings row only when the case
# writes one).
#
# THE RULE. A hub backup json is RETIRED when its newest ledger build row is
# terminal AND (its build folder is gone OR it is older than the window,
# default 7 days). Retiring writes ONE ledger row through bin/jobs-client.sh,
# kind=remote_result key=<p>/<KEY> status=retired. No file under
# state/remote-results is moved, written or deleted (comment 6401167251).
# Dry-run first; one audit line per project per run.
#
#   R1 dry-run: candidates listed, 0 puts        R6 window default and settings row
#   R2 apply: one put per candidate, detail      R7 a failed put: errors=1, retried
#   R3 young / open / absent / unknown: no put   R8 would_page (the replay number)
#   R4 one audit line per run, every field       R9 second apply: already=N, 0 puts
#   R5 bad argument -> rc 2, no audit line       R10 the json dir is byte-identical
#   C1-C3 the cache round-trip (add, mark, prune)
#   M2 a mutant verb that skips the terminal check turns R3 red
#
# Run from anywhere: tests/remote-results-retention.bh-7582-test.sh  (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $*"; }

NOW=1760000000   # pinned clock (D60), passed to the verb as RR_NOW
DAY=86400
H="$T/h"; mkdir -p "$H/bin/lib" "$H/logs"
# The stubs go in FIRST: scratch_install_closure never overwrites a file that
# is already there.
cat > "$H/bin/jobs-client.sh" <<'EOF'
_jobs_req() {
  echo "$2" >> "$HARNESS/calls.txt"
  local k; k=$(printf '%s' "$2" | sed -n 's/.*ticket_id=\([^&]*\).*/\1/p')
  [ -f "$HARNESS/ledger-rc" ] && return "$(cat "$HARNESS/ledger-rc")"
  if [ -f "$HARNESS/ledger/$k" ]; then cat "$HARNESS/ledger/$k"; else printf '{"jobs":[]}'; fi
}
job_ledger_put() {
  printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "${4:-}" >> "$HARNESS/puts.txt"
  [ -f "$HARNESS/put-rc" ] && return "$(cat "$HARNESS/put-rc")"
  return 0
}
EOF
cat > "$H/bin/lib/lane-gate.sh" <<'EOF'
lane_env_apply() {
  [ "${1:-}" = pipeline-health ] || return 0
  [ -f "$HARNESS/row-days" ] && export REMOTE_RESULTS_RETENTION_DAYS="$(cat "$HARNESS/row-days")"
  [ -f "$HARNESS/row-apply" ] && export REMOTE_RESULTS_RETENTION_APPLY="$(cat "$HARNESS/row-apply")"
  return 0
}
EOF
scratch_install_closure bin/remote-results-retention.sh "$H" >/dev/null || { echo "FAIL: scratch_install_closure"; exit 1; }
[ -x "$H/bin/remote-results-retention.sh" ] && [ -f "$H/bin/lib/remote-results-ledger.sh" ] && ok \
  || { echo "FAIL: the verb or its lib was not installed"; exit 1; }
# The suite runs the repo's own files (D41 names them).
cmp -s "$DIR/bin/remote-results-retention.sh" "$H/bin/remote-results-retention.sh" && ok || bad "installed verb differs from the repo's"
cmp -s "$DIR/bin/lib/remote-results-ledger.sh" "$H/bin/lib/remote-results-ledger.sh" && ok || bad "installed lib differs from the repo's"

P=ts; SRD="$H/state/remote-results/$P"; TCF="$H/state/remote-results-terminal/$P.tsv"
AUDIT="$H/logs/remote-results-retention.log"
reset() {
  scratch_rm "$H/state"; scratch_rm "$H/builds"; scratch_rm "$H/ledger"
  rm -f "$H/row-days" "$H/row-apply" "$H/ledger-rc" "$H/put-rc"
  mkdir -p "$SRD" "$H/builds" "$H/ledger"
  : > "$H/calls.txt"; : > "$H/puts.txt"; : > "$AUDIT"
}
mkjson() { printf '{"key":"%s"}\n' "$1" > "$SRD/$1.json"; touch -d "@$((NOW - $2))" "$SRD/$1.json"; }
folder() { mkdir -p "$H/builds/pool-$P-$1-202610010000"; }
relayed() { folder "$1"; : > "$H/builds/pool-$P-$1-202610010000/RELAYED"; }
row() {
  jq -nc --arg k "$1" --arg s "$2" --arg m "${3:-}" \
    '{jobs:[{id:"job-fixture-1",project:"ts",ticket_id:$k,kind:"build",status:$s,meta:$m}]}' > "$H/ledger/$1"
}
# run [verb] [args...] — the verb, as shipped; stdout to $H/out.txt, rc in $RC.
run() {
  local verb="$H/bin/remote-results-retention.sh"
  case "${1:-}" in /*) verb="$1"; shift ;; esac
  env -u REMOTE_RESULTS_RETENTION_DAYS -u REMOTE_RESULTS_RETENTION_APPLY -u STALEREMOTE_LEDGER_READS \
    HARNESS="$H" RR_NOW="$NOW" "$verb" "$@" > "$H/out.txt" 2> "$H/err.txt"
  RC=$?
}
snapshot() { (cd "$H/state/remote-results" && find . -printf '%P %s %T@\n' | LC_ALL=C sort); }
field() { grep -o " $1=[^ ]*" "$AUDIT" | tail -1 | cut -d= -f2; }
ncalls() { grep -c . "$H/calls.txt"; }
nputs() { grep -c . "$H/puts.txt"; }

# The fixture set:
#   A terminal, folder gone, 1d           -> candidate (build folder gone)
#   B terminal, folder present, 8d        -> candidate (older than 7d); folder w/o RELAYED pages
#   C terminal, folder+RELAYED, 2d        -> young, no read, no page
#   D open,     folder gone, 30d          -> kept, would page
#   E absent,   folder gone, 2d           -> kept, would page
#   Q parked QUEUED_FLY, folder gone, 9d  -> open, kept, would page
fixture() {
  reset
  mkjson TK-A $DAY;        row TK-A done 'PR_MERGED https://x.example/pr/1'
  mkjson TK-B $((8*DAY));  row TK-B failed 'REVIEW_BLOCKED fixture'; folder TK-B
  mkjson TK-C $((2*DAY));  row TK-C done 'PR_CREATED x';            relayed TK-C
  mkjson TK-D $((30*DAY)); row TK-D running ''
  mkjson TK-E $((2*DAY))
  mkjson TK-Q $((9*DAY));  row TK-Q parked 'QUEUED_FLY pool'
}

# ── R1 + R4 + R6: dry-run, the audit line, the default window ────────────────
fixture; BEFORE=$(snapshot)
run --project ts --dry-run
[ "$RC" = 0 ] && ok || bad "R1 dry-run rc=$RC"
[ "$(nputs)" = 0 ] && ok || bad "R1 dry-run wrote $(nputs) ledger rows"
[ "$(snapshot)" = "$BEFORE" ] && ok || bad "R1 dry-run changed state/remote-results"
grep -qx 'would-mark ts/TK-A (build folder gone)' "$H/out.txt" && ok || bad "R1 TK-A not listed: $(cat "$H/out.txt")"
grep -qx 'would-mark ts/TK-B (older than 7d)' "$H/out.txt" && ok || bad "R1 TK-B not listed"
[ "$(grep -c '^would-mark' "$H/out.txt")" = 2 ] && ok || bad "R1 want exactly 2 candidates: $(cat "$H/out.txt")"
cmp -s "$H/out.txt" "$H/logs/remote-results-retention-dryrun-ts.txt" && ok || bad "R1 the dry-run file does not hold the candidate list"
[ "$(grep -c . "$AUDIT")" = 1 ] && ok || bad "R4 want 1 audit line, got $(grep -c . "$AUDIT")"
grep -q ' run project=ts dry=1 window=7(default) jsons=6 terminal=2 open=2 absent=1 unknown=0 deferred=0 young=1 marked=0 would_mark=2 already=0 would_page=4 errors=0$' "$AUDIT" \
  && ok || bad "R4/R6 audit line: $(cat "$AUDIT")"
[ "$(ncalls)" = 5 ] && ok || bad "R1 want 5 ledger reads (C is young, no read), got $(ncalls)"

# ── R6: no flag and no row is a dry-run; a settings row of 3 days ────────────
fixture
run --project ts
[ "$(field dry)" = 1 ] && [ "$(nputs)" = 0 ] && ok || bad "R6 no flag, no row must be a dry-run"
fixture; echo 3 > "$H/row-days"
run --project ts --dry-run
[ "$(field window)" = 3 ] && ok || bad "R6 a row of 3 must read window=3: $(cat "$AUDIT")"
grep -q 'TK-C' "$H/out.txt" && bad "R6 TK-C (2d) must still be young at 3d" || ok
grep -qx 'would-mark ts/TK-B (older than 3d)' "$H/out.txt" && ok || bad "R6 TK-B (8d) must be a candidate at 3d"
fixture; echo 0 > "$H/row-days"
run --project ts --dry-run
[ "$(field window)" = '7(default)' ] && ok || bad "R6 a row of 0 must fall back to 7(default)"

# ── R2 + R3 + R10: apply ─────────────────────────────────────────────────────
fixture; BEFORE=$(snapshot)
run --project ts --apply
[ "$RC" = 0 ] && ok || bad "R2 apply rc=$RC"
[ "$(nputs)" = 2 ] && ok || bad "R2 want 2 ledger puts, got $(nputs): $(cat "$H/puts.txt")"
grep -q "^remote_result	ts/TK-A	retired	" "$H/puts.txt" && ok || bad "R2 TK-A row not written"
grep -q "^remote_result	ts/TK-B	retired	" "$H/puts.txt" && ok || bad "R2 TK-B row not written"
DET=$(awk -F'\t' '$2=="ts/TK-A"{print $4}' "$H/puts.txt")
[ "$(jq -r '.json_mtime' <<<"$DET" 2>/dev/null)" = "$((NOW - DAY))" ] \
  && [ "$(jq -r '.reason' <<<"$DET" 2>/dev/null)" = "build folder gone" ] \
  && [ "$(jq -r '.window_days' <<<"$DET" 2>/dev/null)" = 7 ] && ok || bad "R2 detail json: $DET"
for k in TK-C TK-D TK-E TK-Q; do
  grep -q "ts/$k	" "$H/puts.txt" && bad "R3 $k must not be marked" || ok
done
grep -q ' dry=0 .* marked=2 would_mark=0 already=0 .* errors=0$' "$AUDIT" && ok || bad "R2 audit: $(cat "$AUDIT")"
[ ! -s "$H/out.txt" ] && ok || bad "R2 apply printed would-mark lines"
[ "$(snapshot)" = "$BEFORE" ] && ok || bad "R10 apply changed state/remote-results: $(diff <(echo "$BEFORE") <(snapshot))"
grep -q "^TK-A	$((NOW - DAY))	1\$" "$TCF" && ok || bad "R2 TK-A not cached as marked: $(cat "$TCF" 2>/dev/null)"

# ── R9: a second apply run writes nothing new ────────────────────────────────
: > "$H/puts.txt"; : > "$H/calls.txt"
run --project ts --apply
[ "$(nputs)" = 0 ] && [ "$(field already)" = 2 ] && [ "$(field marked)" = 0 ] && ok || bad "R9 second apply: puts=$(nputs) $(tail -1 "$AUDIT")"
# The settings row turns apply on with no flag; --dry-run beats it.
fixture; echo 1 > "$H/row-apply"
run --project ts --dry-run
[ "$(nputs)" = 0 ] && [ "$(field dry)" = 1 ] && ok || bad "R2 --dry-run must beat the apply row"
run --project ts
[ "$(field dry)" = 0 ] && [ "$(field marked)" = 2 ] && ok || bad "R2 the apply row must mark with no flag: $(tail -1 "$AUDIT")"

# ── R3: unreadable ledger -> rc 0, unknown=, nothing written ────────────────
fixture; echo 1 > "$H/ledger-rc"; BEFORE=$(snapshot)
run --project ts --apply
[ "$RC" = 0 ] && [ "$(field unknown)" = 5 ] && [ "$(nputs)" = 0 ] && ok || bad "R3 unreadable: rc=$RC puts=$(nputs) $(cat "$AUDIT")"
[ "$(snapshot)" = "$BEFORE" ] && ok || bad "R10 an unreadable ledger changed state/remote-results"

# ── R7: a failed put is errors=1, not cached as marked, retried next run ────
reset; mkjson TK-A $DAY; row TK-A done 'PR_MERGED x'; echo 1 > "$H/put-rc"
run --project ts --apply
[ "$RC" = 0 ] && [ "$(field errors)" = 1 ] && [ "$(field marked)" = 0 ] && ok || bad "R7 failed put: rc=$RC $(cat "$AUDIT")"
grep -q '	1$' "$TCF" 2>/dev/null && bad "R7 a failed put was cached as marked" || ok
rm -f "$H/put-rc"; : > "$H/puts.txt"
run --project ts --apply
[ "$(nputs)" = 1 ] && [ "$(field marked)" = 1 ] && ok || bad "R7 the next run must retry: puts=$(nputs) $(tail -1 "$AUDIT")"

# ── R8: would_page counts only what staleremote would page ──────────────────
reset
mkjson TK-N1 7200                                   # no folder, absent -> page
mkjson TK-N2 7200; row TK-N2 running ''             # no folder, open   -> page
mkjson TK-N3 1000                                   # no folder, absent, young -> no page
mkjson TK-N4 7200; row TK-N4 done 'PR_MERGED x'     # terminal -> no page
mkjson TK-N5 7200; relayed TK-N5                    # RELAYED -> no page
run --project ts --dry-run
[ "$(field would_page)" = 2 ] && ok || bad "R8 would_page: $(cat "$AUDIT")"

# ── R5: bad arguments ────────────────────────────────────────────────────────
for a in "--bogus" "--project" "--max-reads x" "--project ../x" "--project ts --all"; do
  reset
  # shellcheck disable=SC2086
  run $a
  [ "$RC" = 2 ] && [ ! -s "$AUDIT" ] && ok || bad "R5 '$a': rc=$RC audit=$(cat "$AUDIT")"
done

# ── the read cap, and --all (one audit line per project) ─────────────────────
fixture
run --project ts --dry-run --max-reads 2
[ "$(ncalls)" = 2 ] && [ "$(field deferred)" = 3 ] && ok || bad "cap: calls=$(ncalls) $(cat "$AUDIT")"
fixture; mkdir -p "$H/state/remote-results/zz-os"
run --all --dry-run
[ "$(grep -c ' run project=' "$AUDIT")" = 2 ] && grep -q 'project=zz-os .* jsons=0 ' "$AUDIT" && ok || bad "--all: $(cat "$AUDIT")"

# ── as documented: the replay command from the verb's header ─────────────────
fixture
REPLAY=$(sed -n 's/^#     \(bin\/remote-results-retention.sh --all --dry-run .*\)$/\1/p' "$DIR/bin/remote-results-retention.sh")
[ -n "$REPLAY" ] && ok || bad "the header has no replay command"
# shellcheck disable=SC2086
run ${REPLAY#bin/remote-results-retention.sh }
[ "$RC" = 0 ] && [ "$(grep -c '^would-mark' "$H/out.txt")" = 2 ] && ok || bad "replay command: rc=$RC $(cat "$H/out.txt")"

# ── C1-C3: the cache round-trip through the real lib ─────────────────────────
C="$T/c"; mkdir -p "$C/jsons"; : > "$C/jsons/K1.json"; : > "$C/jsons/K2.json"
CR=$(bash -c '. "$1"; f="$2/tc/x.tsv"
  rr_terminal_cache_add "$f" K1 100
  rr_terminal_cache_load "$f"; rr_terminal_cache_has K1 100 && echo C1a
  rr_terminal_cache_has K1 101 || echo C1b
  rr_terminal_cache_marked K1 100 || echo C1c
  rr_terminal_cache_mark "$f" K1 100; rr_terminal_cache_add "$f" K2 200; rr_terminal_cache_add "$f" K3 300
  rr_terminal_cache_load "$f"; rr_terminal_cache_marked K1 100 && echo C2a
  rr_terminal_cache_marked K2 200 || echo C2b
  rr_terminal_cache_prune "$f" "$2/jsons"
  cat "$f"' _ "$DIR/bin/lib/remote-results-ledger.sh" "$C")
for t in C1a C1b C1c C2a C2b; do grep -qx "$t" <<<"$CR" && ok || bad "$t cache round-trip: $CR"; done
[ "$(grep -c $'^K' <<<"$CR")" = 2 ] && grep -qx $'K1\t100\t1' <<<"$CR" && grep -qx $'K2\t200\t0' <<<"$CR" \
  && ok || bad "C3 prune must keep one line per live key and drop K3: $CR"

# ── M2: a verb that skips the terminal check marks open/absent jsons ────────
sed 's/^\( *\)open) *open=\$((open+1)); continue ;;/\1open) open=$((open+1)) ;;/' \
  "$H/bin/remote-results-retention.sh" > "$H/bin/mutant-retention.sh"; chmod +x "$H/bin/mutant-retention.sh"
cmp -s "$H/bin/remote-results-retention.sh" "$H/bin/mutant-retention.sh" && bad "M2 the mutation changed nothing"
fixture
run "$H/bin/mutant-retention.sh" --project ts --apply
grep -qE 'ts/(TK-D|TK-Q)	' "$H/puts.txt" && ok || bad "M2 the R3 check stayed green on a verb that marks open rows"

[ -s "$H/err.txt" ] && sed 's/^/stderr: /' "$H/err.txt" | head -5
echo "remote-results-retention.bh-7582: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
