#!/bin/bash
# tests/split-chain.bh-1655-test.sh — BH-1655: a merged split child makes the
# next sibling launchable on a POLLING board.
#
# THE BUG. On an in-app board (project-3, project-1, project-2, project-4) nothing re-read
# a chained split child after its earlier sibling's PR merged:
# bin/unblocked-children.sh exits for every in-app board, the board status of a
# merged child is `review` (so the fingerprint did not move), and the queue
# PR-gate only reads PR numbers written into READY-QUEUE lines. So
# bin/triage-gate.sh answered `SKIP no-change` every tick while TK-202 waited on
# a TK-201 that had already merged (project-3, 12:28Z -> 13:18Z).
#
# What this suite drives, all REAL code against a scratch harness:
#   L*  bin/lib/split-chain.sh's deterministic pass (split_chain_due/_gate)
#   G*  bin/triage-gate.sh run as a script: step 1c answers `RUN split-ready`
#   S*  bin/run-triage.sh (roots rewritten, the event-wake-scope-test idiom):
#       a split-ready tick carries the `board split: UNBLOCKED` line
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/split-chain.bh-1655-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "split-chain: jq missing, cannot run" >&2; exit 1; }
command -v flock >/dev/null 2>&1 || { echo "split-chain: flock missing, cannot run" >&2; exit 1; }

H="$T/h"
P=project-3
NOW=$(date +%s)
mkdir -p "$H/bin/lib" "$H/state" "$H/logs" "$H/locks" "$H/flags" "$H/builds" "$H/env" "$H/fixture"
LIB_SRC="$DIR/bin/lib/split-chain.sh"
# Test-first: absent until the feature lands, and every case below says so.
[ -f "$LIB_SRC" ] && cp "$LIB_SRC" "$H/bin/lib/split-chain.sh"
cp "$DIR/bin/triage-gate.sh" "$H/bin/triage-gate.sh"
# BH-1955: the generic arm resolves its token through these two libs.
mkdir -p "$H/bin/lib" && cp "$DIR/bin/lib/board-creds.sh" "$DIR/bin/lib/internal-token.sh" "$H/bin/lib/"
chmod +x "$H/bin/triage-gate.sh"
: > "$H/env/global.env"
printf 'PROJECT_3_APP_BASE=https://project-3.example\nproject-3_INTERNAL_API_TOKEN=tok\n' > "$H/env/project-3.env"
printf 'GEN_API_BASE=https://gen.example\nGEN_INTERNAL_API_TOKEN=tok\n' > "$H/env/gen-os.env"

# --- stubs ---------------------------------------------------------------------
cat > "$H/bin/fleet-conf.sh" <<'SH'
#!/bin/bash
case "$1/$2" in
  project-3/repo)           echo example-org/project-3 ;;
  project-3/board_prefix)   echo /api/feature-board ;;
  gen-os/repo)            echo example-org/gen-os ;;
  gen-os/board_prefix)    echo /api/board ;;
  issues-os/repo)         echo example-org/issues-os ;;
  issues-os/board_prefix) echo - ;;
  *) exit 1 ;;
esac
SH
chmod +x "$H/bin/fleet-conf.sh"

# The in-app board: one listing per host, served from the fixture dir.
cat > "$H/bin/curl" <<SH
#!/bin/bash
OUT=""; URL=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    -o) shift; OUT="\${1:-}" ;;
    -H|-m|-w) shift ;;
    -*) : ;;
    *) URL="\$1" ;;
  esac
  shift || true
done
case "\$URL" in *project-3.example*) D=project-3 ;; *gen.example*) D=gen-os ;; *) exit 22 ;; esac
case "\$URL" in
  */boards/*/tickets) F="$H/fixture/\$D/tickets.json" ;;
  */boards)           F="$H/fixture/\$D/boards.json" ;;
  *) exit 22 ;;
esac
[ -f "\$F" ] || exit 22
if [ -n "\$OUT" ]; then cat "\$F" > "\$OUT"; else cat "\$F"; fi
exit 0
SH
chmod +x "$H/bin/curl"

# The REST contract's variable-assigning PR-state read, answered from fixtures:
# fixture/pr-<n> holds open|merged|closed, fixture/gh-mode=fail answers rc 75
# (rate limited) with the variable empty, exactly like the real helper. Every
# call is counted, so "the cache answered" is provable.
cat > "$H/bin/lib/gh-rest.sh" <<'SH'
gh_rest_pr_state_var() {
  # `_ghrv_` locals, like the real helper: a plain `st` here would shadow the
  # caller's variable of the same name and the answer would never reach it.
  local _ghrv_v="$1" _ghrv_slug="$2" _ghrv_n="$3" _ghrv_st=""
  echo "$_ghrv_slug $_ghrv_n" >> "$HARNESS/fixture/gh-calls"
  if [ "$(cat "$HARNESS/fixture/gh-mode" 2>/dev/null)" = fail ]; then
    printf -v "$_ghrv_v" '%s' ""; return 75
  fi
  _ghrv_st=$(cat "$HARNESS/fixture/pr-$_ghrv_n" 2>/dev/null)
  [ -n "$_ghrv_st" ] || { printf -v "$_ghrv_v" '%s' ""; return 44; }
  printf -v "$_ghrv_v" '%s' "$_ghrv_st"; return 0
}
SH

board_fixture() { # board_fixture <project> <prefix>
  local p="$1" x="$2"
  mkdir -p "$H/fixture/$p"
  printf '[{"id":"b1","keyPrefix":"%s"}]\n' "$x" > "$H/fixture/$p/boards.json"
  cat > "$H/fixture/$p/tickets.json" <<EOF
[
 {"id":7150,"number":150,"status":"review","waitingOn":"team","triageVerdict":"ready","commentCount":2,"lastActivityAt":"2026-09-23T10:00:00Z","title":"unrelated shipped fix"},
 {"id":7200,"number":200,"status":"in_progress","waitingOn":"team","triageVerdict":"ready","commentCount":3,"lastActivityAt":"2026-09-23T10:00:00Z","title":"the parent"},
 {"id":7201,"number":201,"status":"review","waitingOn":"team","triageVerdict":"ready","commentCount":2,"lastActivityAt":"2026-09-23T12:28:00Z","title":"contract slice"},
 {"id":7202,"number":202,"status":"todo","waitingOn":"team","triageVerdict":"ready","commentCount":1,"lastActivityAt":"2026-09-23T10:00:00Z","title":"second slice"},
 {"id":7203,"number":203,"status":"todo","waitingOn":"team","triageVerdict":"ready","commentCount":1,"lastActivityAt":"2026-09-23T10:00:00Z","title":"third slice"}
]
EOF
}
board_fixture project-3 FR
board_fixture gen-os GN

# res <project> <KEY> <line1> — a finished build record, already closed out on
# the board (COMMENTED), so the gate's results-sweep brake does not fire.
res() {
  local d="$H/builds/$1-$2-$((RANDOM))$((RANDOM))"
  mkdir -p "$d"; printf '%s\nTICKET_ID: x\n' "$3" > "$d/RESULT"; touch "$d/COMMENTED"
  printf '%s\n' "$d"
}
reset() {
  for _p in "$H/state" "$H/logs" "$H/locks" "$H/flags" "$H/builds" "$H/fixture/gh-calls" "$H/fixture/gh-mode" "$H/fixture"/pr-*; do scratch_rm "$_p"; done
  mkdir -p "$H/state" "$H/logs" "$H/locks" "$H/flags" "$H/builds"
  : > "$H/logs/READY-QUEUE.log"
  return 0
}
keymap() { # the key<->id map the gate writes for the OPEN tickets
  jq -n '{"7200":"TK-200","TK-200":"7200","7201":"TK-201","TK-201":"7201","7202":"TK-202","TK-202":"7202","7203":"TK-203","TK-203":"7203"}' > "$H/state/$P.keymap.json"
}
chain() { # the project-3 chain: TK-200 decomposed into TK-201,TK-202,TK-203
  reset; keymap
  res "$P" TK-200 "DECOMPOSED TK-201,TK-202,TK-203" >/dev/null
}
ghcalls() { [ -f "$H/fixture/gh-calls" ] && grep -c . "$H/fixture/gh-calls" || echo 0; }

# The lib, sourced in THIS shell exactly as the gate and the scope source it.
HARNESS="$H"
# shellcheck source=/dev/null
. "$H/bin/lib/gh-rest.sh"
# shellcheck source=/dev/null
[ -r "$H/bin/lib/split-chain.sh" ] && . "$H/bin/lib/split-chain.sh"
HAVE_LIB=0; command -v split_chain_due >/dev/null 2>&1 && HAVE_LIB=1
[ "$HAVE_LIB" = 1 ] || bad "bin/lib/split-chain.sh is missing or defines no split_chain_due"
due() { [ "$HAVE_LIB" = 1 ] || { echo "__NO_LIB__"; return 0; }; split_chain_due "$H" "${1:-$P}" 2>/dev/null | cut -f1 | tr '\n' ' ' | sed 's/ $//'; }
sgate() { [ "$HAVE_LIB" = 1 ] || { echo "__NO_LIB__"; return 0; }; split_chain_gate "$H" "${1:-$P}" 2>/dev/null; }

# --- L1: a merged first child makes the second one due ------------------------
chain
res "$P" TK-201 "PR_MERGED https://github.com/example-org/project-3/pull/376" >/dev/null
[ "$(due)" = "TK-202" ] && ok || bad "L1: want exactly TK-202 due, got '$(due)'"
L1_LINE=$([ "$HAVE_LIB" = 1 ] && split_chain_due "$H" "$P" 2>/dev/null)
[ "$L1_LINE" = "TK-202	TK-200	TK-201=#376" ] && ok || bad "L1: due line shape, got '$L1_LINE'"

# --- L2: a PR_CREATED sibling the REST read says merged; then the cache --------
chain
res "$P" TK-201 "PR_CREATED https://github.com/example-org/project-3/pull/376 (tier 2)" >/dev/null
echo merged > "$H/fixture/pr-376"
[ "$(due)" = "TK-202" ] && ok || bad "L2: GitHub says merged, want TK-202 due, got '$(due)'"
[ -f "$H/state/split-chain/$P/merged/TK-201" ] && ok || bad "L2: merged cache marker not written"
rm -f "$H/fixture/gh-calls"; echo fail > "$H/fixture/gh-mode"
[ "$(due)" = "TK-202" ] && ok || bad "L2: cache hit must still answer due with GitHub down, got '$(due)'"
[ "$(ghcalls)" = 0 ] && ok || bad "L2: a cached merge must cost 0 GitHub reads, got $(ghcalls)"

# --- L3 (test b): TK-201 merged, TK-202 open -> TK-203 NOT due ---------------
chain
res "$P" TK-201 "PR_MERGED https://github.com/example-org/project-3/pull/376" >/dev/null
res "$P" TK-202 "PR_CREATED https://github.com/example-org/project-3/pull/377" >/dev/null
echo open > "$H/fixture/pr-377"
[ -z "$(due)" ] && ok || bad "L3: TK-202 open + has its own PR -> nothing due, got '$(due)'"

# --- L3b (test b, the other half): an EARLIER sibling is unmerged even though
# the immediately previous one merged -> not due. "Every earlier", not "the one
# before".
chain
res "$P" TK-201 "PR_CREATED https://github.com/example-org/project-3/pull/376" >/dev/null
echo open > "$H/fixture/pr-376"
res "$P" TK-202 "PR_MERGED https://github.com/example-org/project-3/pull/377" >/dev/null
[ -z "$(due)" ] && ok || bad "L3b: TK-201 still open -> TK-203 NOT due, got '$(due)'"

# --- L4: a GitHub read that fails is NOT merged, and nothing is cached --------
chain
res "$P" TK-201 "PR_CREATED https://github.com/example-org/project-3/pull/376" >/dev/null
echo merged > "$H/fixture/pr-376"; echo fail > "$H/fixture/gh-mode"
[ -z "$(due)" ] && ok || bad "L4: rc 75 must read not-merged, got '$(due)'"
[ ! -e "$H/state/split-chain/$P/merged/TK-201" ] && ok || bad "L4: an error wrote the merged cache"
rm -f "$H/fixture/gh-mode"; echo closed > "$H/fixture/pr-376"
[ -z "$(due)" ] && ok || bad "L4: closed-unmerged must read not-merged, got '$(due)'"

# --- L5: TK-202 is not idle -> not due ----------------------------------------
chain
res "$P" TK-201 "PR_MERGED https://github.com/example-org/project-3/pull/376" >/dev/null
res "$P" TK-202 "PR_CREATED https://github.com/example-org/project-3/pull/380" >/dev/null
[ -z "$(due)" ] && ok || bad "L5: TK-202 with its own PR must not be due, got '$(due)'"
chain
res "$P" TK-201 "PR_MERGED https://github.com/example-org/project-3/pull/376" >/dev/null
mkdir -p "$H/builds/$P-TK-202-inflight"
[ -z "$(due)" ] && ok || bad "L5: TK-202 building (dir, no RESULT) must not be due, got '$(due)'"
chain
res "$P" TK-201 "PR_MERGED https://github.com/example-org/project-3/pull/376" >/dev/null
res "$P" TK-202 "BUILD_DEFERRED file overlap" >/dev/null
[ "$(due)" = TK-202 ] && ok || bad "L5: BUILD_DEFERRED is a re-offer terminal, TK-202 must stay due, got '$(due)'"
LOCK="$H/locks/build-key-$P-TK-202.lock"
( exec 9>"$LOCK"; flock -x 9; sleep 30 ) &
LPID=$!
for _ in $(seq 1 50); do ( exec 9>>"$LOCK"; flock -n 9 ) 2>/dev/null || break; sleep 0.1; done
[ -z "$(due)" ] && ok || bad "L5: TK-202's build lock is held, must not be due, got '$(due)'"
kill "$LPID" 2>/dev/null; wait "$LPID" 2>/dev/null
[ "$(due)" = TK-202 ] && ok || bad "L5: lock released, TK-202 due again, got '$(due)'"

# --- L6: closed on the board / no keymap -> nothing due -----------------------
chain
res "$P" TK-201 "PR_MERGED https://github.com/example-org/project-3/pull/376" >/dev/null
jq 'del(.["TK-202"], .["7202"])' "$H/state/$P.keymap.json" > "$H/km" && mv "$H/km" "$H/state/$P.keymap.json"
[ -z "$(due)" ] && ok || bad "L6: TK-202 absent from keymap must not be due, got '$(due)'"
rm -f "$H/state/$P.keymap.json"
[ -z "$(due)" ] && ok || bad "L6: no keymap -> nothing due, got '$(due)'"
printf 'not json' > "$H/state/$P.keymap.json"
[ -z "$(due)" ] && ok || bad "L6: unparseable keymap -> nothing due, got '$(due)'"

# --- L7: a PR on another repo is not this project's merge ---------------------
chain
res "$P" TK-201 "PR_CREATED https://github.com/Other/repo/pull/1" >/dev/null
echo merged > "$H/fixture/pr-1"
[ -z "$(due)" ] && ok || bad "L7: a foreign-repo PR must not count as merged, got '$(due)'"
[ "$(ghcalls)" = 0 ] && ok || bad "L7: a foreign-repo PR must not be looked up, got $(ghcalls) reads"

# --- L8 (test c): two gate passes -> one offer, one log line -------------------
chain
res "$P" TK-201 "PR_MERGED https://github.com/example-org/project-3/pull/376" >/dev/null
G1OUT=$(sgate); G2OUT=$(sgate)
[ "$G1OUT" = TK-202 ] && ok || bad "L8: first gate pass must print TK-202, got '$G1OUT'"
[ -z "$G2OUT" ] && ok || bad "L8: second gate pass must print nothing, got '$G2OUT'"
OFF=$(cat "$H/state/split-chain/$P/offered/TK-202" 2>/dev/null)
case "$OFF" in ''|*[!0-9]*) bad "L8: offered marker missing or not an epoch: '$OFF'" ;; *) ok ;; esac
N=$(grep -c 'SPLIT_READY TK-202' "$H/logs/$P.log" 2>/dev/null); N=${N:-0}
[ "$N" = 1 ] && ok || bad "L8: want exactly one SPLIT_READY TK-202 log line, got $N"
grep -q "\[$P\] SPLIT_READY TK-202 (after TK-201=#376)" "$H/logs/$P.log" 2>/dev/null && ok || bad "L8: log line shape: $(cat "$H/logs/$P.log" 2>/dev/null)"
[ "$(tr -s ' \n' ' ' < "$H/state/split-ready-keys-$P" 2>/dev/null | sed 's/ $//')" = TK-202 ] && ok || bad "L8: keys file must hold TK-202 once"
# ...and the remind window re-offers it.
echo $((NOW - 21601)) > "$H/state/split-chain/$P/offered/TK-202"
[ "$(sgate)" = TK-202 ] && ok || bad "L8: past SPLIT_CHAIN_REMIND_S it must be offered again"

# --- L9: a DECOMPOSED record older than the lookback is ignored ---------------
chain
res "$P" TK-201 "PR_MERGED https://github.com/example-org/project-3/pull/376" >/dev/null
for r in "$H/builds/$P-TK-200-"*/RESULT; do touch -d "@$((NOW - 1300000))" "$r"; done
[ -z "$(due)" ] && ok || bad "L9: a parent past the lookback must be ignored, got '$(due)'"

# --- L10: junk tokens in the DECOMPOSED line ----------------------------------
reset; keymap
res "$P" TK-200 "DECOMPOSED TK-201, TK-200.1,,TK-202" >/dev/null
res "$P" TK-201 "PR_MERGED https://github.com/example-org/project-3/pull/376" >/dev/null
[ "$(due)" = TK-202 ] && ok || bad "L10: 'TK-201, TK-200.1,,TK-202' must parse to TK-201,TK-202 -> TK-202 due, got '$(due)'"
# The first child is never "released" and a non-split merge releases nothing.
reset; keymap
res "$P" TK-150 "PR_MERGED https://github.com/example-org/project-3/pull/300" >/dev/null
res "$P" TK-200 "DECOMPOSED TK-201,TK-202" >/dev/null
[ -z "$(due)" ] && ok || bad "L10: the first child / a non-split merge must release nothing, got '$(due)'"

# --- L11: the kill flag -------------------------------------------------------
reset
if [ "$HAVE_LIB" = 1 ]; then
  [ "$(split_chain_on "$H")" = 1 ] && ok || bad "L11: no flag -> split_chain_on 1"
  touch "$H/flags/split-chain-off"
  [ "$(split_chain_on "$H")" = 0 ] && ok || bad "L11: flags/split-chain-off -> split_chain_on 0"
else
  bad "L11: no split_chain_on"
fi

# --- L12: the lookup cap -------------------------------------------------------
reset; keymap
jq '. + {"7301":"TK-301","TK-301":"7301","7302":"TK-302","TK-302":"7302"}' "$H/state/$P.keymap.json" > "$H/km" && mv "$H/km" "$H/state/$P.keymap.json"
res "$P" TK-200 "DECOMPOSED TK-201,TK-202" >/dev/null
res "$P" TK-300 "DECOMPOSED TK-301,TK-302" >/dev/null
res "$P" TK-201 "PR_CREATED https://github.com/example-org/project-3/pull/376" >/dev/null
res "$P" TK-301 "PR_CREATED https://github.com/example-org/project-3/pull/476" >/dev/null
echo open > "$H/fixture/pr-376"; echo open > "$H/fixture/pr-476"
L12=$(SPLIT_CHAIN_MAX_LOOKUPS=1 due)
[ -z "$L12" ] && ok || bad "L12: nothing merged, nothing due, got '$L12'"
[ "$(ghcalls)" = 1 ] && ok || bad "L12: SPLIT_CHAIN_MAX_LOOKUPS=1 must cap the reads at 1, got $(ghcalls)"
grep -q 'split-chain: lookup cap hit' "$H/logs/$P.log" 2>/dev/null && ok || bad "L12: the cap must be logged"

# =============================================================================
# G: bin/triage-gate.sh as a script, in a world that answered SKIP before.
# =============================================================================
gate() { PATH="$H/bin:$PATH" HARNESS="$H" bash "$H/bin/triage-gate.sh" "$@" 2>>"$T/gate.err"; }
gworld() { # gworld <project> <prefix> — TK-200 split, TK-201 merged, board seeded
  local p="$1" x="$2"
  reset
  res "$p" "$x-200" "DECOMPOSED $x-201,$x-202,$x-203" >/dev/null
  res "$p" "$x-201" "PR_MERGED https://github.com/example-org/$p/pull/376" >/dev/null
  gate "$p" --seed >/dev/null
}

# G1 (test a): the stall world answers RUN split-ready and names TK-202.
gworld "$P" FR
G1=$(gate "$P")
[ "$G1" = "RUN split-ready" ] && ok || bad "G1: want 'RUN split-ready', got '$G1'"
grep -qx TK-202 "$H/state/split-ready-keys-$P" 2>/dev/null && ok || bad "G1: state/split-ready-keys-$P must hold TK-202"
# G3 (test c): the second tick of the same world is the ordinary no-change skip.
G3=$(gate "$P")
case "$G3" in "SKIP no-change"*) ok ;; *) bad "G3: second tick must SKIP no-change, got '$G3'" ;; esac

# G2 (test b): only one of two earlier siblings merged -> SKIP, byte-identical
# to the gate with the lib removed.
g2world() {
  reset
  res "$P" TK-200 "DECOMPOSED TK-201,TK-202,TK-203" >/dev/null
  res "$P" TK-201 "PR_CREATED https://github.com/example-org/project-3/pull/376" >/dev/null
  res "$P" TK-202 "PR_MERGED https://github.com/example-org/project-3/pull/377" >/dev/null
  echo open > "$H/fixture/pr-376"
  gate "$P" --seed >/dev/null
}
nolib() { # run the gate with bin/lib/split-chain.sh absent from the scratch tree
  local out
  [ -f "$H/bin/lib/split-chain.sh" ] && mv "$H/bin/lib/split-chain.sh" "$T/split-chain.sh.away"
  out=$(gate "$@")
  [ -f "$T/split-chain.sh.away" ] && mv "$T/split-chain.sh.away" "$H/bin/lib/split-chain.sh"
  printf '%s' "$out"
}
g2world; G2=$(gate "$P")
g2world; G2N=$(nolib "$P")
case "$G2" in "SKIP no-change"*) ok ;; *) bad "G2: want SKIP no-change, got '$G2'" ;; esac
[ "$G2" = "$G2N" ] && ok || bad "G2: with the lib '$G2' vs without '$G2N'"
[ ! -e "$H/state/split-ready-keys-$P" ] && ok || bad "G2: no keys file may be written"

# G4 (test d): only a non-split merge -> byte-identical to the gate without the
# lib, and no split-chain state at all.
g4world() {
  reset
  res "$P" TK-150 "PR_MERGED https://github.com/example-org/project-3/pull/300" >/dev/null
  gate "$P" --seed >/dev/null
}
g4world; G4=$(gate "$P"); G4DIR=0; [ -e "$H/state/split-chain" ] && G4DIR=1
g4world; G4N=$(nolib "$P")
case "$G4" in "SKIP no-change"*) ok ;; *) bad "G4: want SKIP no-change, got '$G4'" ;; esac
[ "$G4" = "$G4N" ] && ok || bad "G4: with the lib '$G4' vs without '$G4N'"
[ "$G4DIR" = 0 ] && ok || bad "G4: a non-split merge created state/split-chain"

# G5: a generic in-app project (the gate's `*)` arm) behaves as G1; a
# GitHub-Issues project with the same records never takes step 1c.
gworld gen-os GN
G5=$(gate gen-os)
[ "$G5" = "RUN split-ready" ] && ok || bad "G5: generic in-app project must answer RUN split-ready, got '$G5'"
reset
res issues-os IS-200 "DECOMPOSED IS-201,IS-202" >/dev/null
res issues-os IS-201 "PR_MERGED https://github.com/example-org/issues-os/pull/9" >/dev/null
printf '{"IS-201":"201","IS-202":"202"}' > "$H/state/issues-os.keymap.json"
G5I=$(gate issues-os)
[ "$G5I" != "RUN split-ready" ] && ok || bad "G5: a GitHub-Issues project must not take step 1c"
[ ! -e "$H/state/split-chain/issues-os" ] && ok || bad "G5: a GitHub-Issues project wrote split-chain state"

# G6: the kill flag -> G1's world answers SKIP no-change.
gworld "$P" FR
touch "$H/flags/split-chain-off"
G6=$(gate "$P")
case "$G6" in "SKIP no-change"*) ok ;; *) bad "G6: flags/split-chain-off must leave SKIP no-change, got '$G6'" ;; esac

# =============================================================================
# S: the tick. split_chain_take_lines on its own, then the REAL run-triage.sh.
# =============================================================================
take() { [ "$HAVE_LIB" = 1 ] || { echo "__NO_LIB__"; return 0; }; split_chain_take_lines "$H" "$P" 2>/dev/null; }
sworld() {
  chain
  res "$P" TK-201 "PR_MERGED https://github.com/example-org/project-3/pull/376" >/dev/null
  printf '{"b1":[{"id":7202,"title":"second slice","status":"todo"}]}' > "$H/state/$P.gate.json"
  sgate >/dev/null
}
# S3: the key went stale (TK-202 got its own PR) -> no line, file consumed.
sworld
res "$P" TK-202 "PR_CREATED https://github.com/example-org/project-3/pull/380" >/dev/null
[ -z "$(take)" ] && ok || bad "S3: a key that has since got a PR must emit no line, got '$(take)'"
[ ! -e "$H/state/split-ready-keys-$P" ] && ok || bad "S3: the keys file is one-shot"
# S4: a keys file older than the remind window is deleted unread.
sworld
touch -d "@$((NOW - 21700))" "$H/state/split-ready-keys-$P"
[ -z "$(take)" ] && ok || bad "S4: a stale keys file must emit nothing"
[ ! -e "$H/state/split-ready-keys-$P" ] && ok || bad "S4: a stale keys file must be deleted"
# The flag leaves the take a no-op too: nothing read, nothing removed.
sworld
touch "$H/flags/split-chain-off"
[ -z "$(take)" ] && ok || bad "S-flag: flags/split-chain-off must emit nothing"
rm -f "$H/flags/split-chain-off"

# S1/S2 through bin/run-triage.sh: a split-ready tick's prompt carries the line.
R="$T/r"
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
mkdir -p "$R/bin/lib/rt" "$R/logs" "$R/state" "$R/locks" "$R/env" "$R/flags" "$R/prompts" "$R/builds" "$R/fixture" "$T/calls" "$T/repos"
model_routes_fixture "$R" "$P" || exit 1
: > "$R/env/global.env"
echo "SOP for $P. Fetch the thread. Do the work." > "$R/prompts/$P.md"
export FLEET_CONF="$DIR/fleet.conf"
sed -e "s|/root/harness|$R|g" -e "s|/root/repos|$T/repos|g" "$DIR/bin/run-triage.sh" > "$R/bin/run-triage.sh"
chmod +x "$R/bin/run-triage.sh"
for s in "$DIR"/bin/lib/rt/*.sh; do sed -e "s|/root/harness|$R|g" -e "s|/root/repos|$T/repos|g" "$s" > "$R/bin/lib/rt/$(basename "$s")"; done
for s in fleet-conf.sh project-of.sh decision-log.sh; do ln -sf "$DIR/bin/$s" "$R/bin/$s"; done
cp "$DIR/bin/lib/triage-shards-lib.sh" "$R/bin/lib/triage-shards-lib.sh"
[ -f "$LIB_SRC" ] && cp "$LIB_SRC" "$R/bin/lib/split-chain.sh"
cp "$H/bin/lib/gh-rest.sh" "$R/bin/lib/gh-rest.sh"
printf '#!/bin/sh\necho box-project-3-2\n' > "$R/bin/box-name.sh"; chmod +x "$R/bin/box-name.sh"
cat > "$R/bin/triage-gate.sh" <<STUB
#!/bin/bash
PRJ="\$1"; MODE="\${2:-}"
printf '%s %s\n' "\$PRJ" "\$MODE" >> "$R/gate-calls.log"
cp "$R/fixture/pending.json" "$R/state/\$PRJ.gate.pending"
[ "\$MODE" = "--pending" ] && exit 0
echo "RUN split-ready"
exit 0
STUB
chmod +x "$R/bin/triage-gate.sh"
printf '#!/bin/bash\nexit 2\n' > "$R/bin/gate-diff.sh"; chmod +x "$R/bin/gate-diff.sh"
printf '#!/bin/bash\ncat >/dev/null; exit 0\n' > "$R/bin/unblocked-children.sh"; chmod +x "$R/bin/unblocked-children.sh"
printf '#!/bin/sh\necho "CONTRACT: end with DECISION lines."\n' > "$R/bin/triage-contract.sh"; chmod +x "$R/bin/triage-contract.sh"
printf '#!/bin/sh\nexit 0\n' > "$R/bin/beat.sh"; chmod +x "$R/bin/beat.sh"
cat > "$R/bin/agent-call.sh" <<'STUB'
#!/bin/bash
D="${CALLDIR:?}"
PR="$6"; case "$PR" in @/*) PR=$(cat "${PR#@}") ;; esac
F=$(mktemp "$D/prompt-XXXXXXXX.txt")
printf '%s' "$PR" > "$F"
echo "tickets=1 done" > "$5"
exit 0
STUB
chmod +x "$R/bin/agent-call.sh"
FPJ='{"b1":[{"id":7202,"title":"second slice","status":"todo","waitingOn":"team","triageVerdict":"ready","commentCount":1,"lastActivityAt":"2026-09-23T10:00:00Z"}]}'
printf '%s' "$FPJ" > "$R/fixture/pending.json"
printf '%s' "$FPJ" > "$R/state/$P.gate.json"
printf '{"7200":"TK-200","TK-200":"7200","7201":"TK-201","TK-201":"7201","7202":"TK-202","TK-202":"7202","7203":"TK-203","TK-203":"7203"}' > "$R/state/$P.keymap.json"
: > "$R/logs/READY-QUEUE.log"
for spec in "TK-200|DECOMPOSED TK-201,TK-202,TK-203" "TK-201|PR_MERGED https://github.com/example-org/project-3/pull/376"; do
  d="$R/builds/$P-${spec%%|*}-1"; mkdir -p "$d"; printf '%s\n' "${spec#*|}" > "$d/RESULT"; touch "$d/COMMENTED"
done
# The gate's own write, as step 1c makes it: offered marker, then the keys file.
mkdir -p "$R/state/split-chain/$P/offered"; echo "$NOW" > "$R/state/split-chain/$P/offered/TK-202"
echo TK-202 > "$R/state/split-ready-keys-$P"
CALLDIR="$T/calls" TRIAGE_SHARDS=0 HARNESS="$R" "$R/bin/run-triage.sh" "$P" >/dev/null 2>"$T/rt.err"
PROMPT=$(cat "$(ls "$T/calls"/prompt-*.txt 2>/dev/null | head -1)" 2>/dev/null)
S1LINE=$(printf '%s\n' "$PROMPT" | grep '^board split: UNBLOCKED TK-202 ' | head -1)
case "$S1LINE" in
  'board split: UNBLOCKED TK-202 "second slice" (TK-202 — split sibling of TK-200, dependency TK-201=#376 merged'*) ok ;;
  *) bad "S1: the tick prompt must carry the split line; prompt head: $(printf '%s' "$PROMPT" | head -5 | tr '\n' '|') err: $(head -3 "$T/rt.err" | tr '\n' '|')" ;;
esac
case "$S1LINE" in *'SPLIT_DEFER TK-202 :: <reason>'*) ok ;; *) bad "S1: the line must carry the SPLIT_DEFER instruction" ;; esac
grep -q '^TICK SCOPE (deterministic' <<<"$PROMPT" && ok || bad "S1: a split-ready tick must be a SCOPED tick"
. "$DIR/bin/lib/triage-shards-lib.sh"
SK=$(triage_shard_key board "$P" 0 "$S1LINE" 2>/dev/null)
[ "$SK" = TK-202 ] && ok || bad "S1: triage_shard_key board must parse TK-202 out of the line, got '$SK'"
[ ! -e "$R/state/split-ready-keys-$P" ] && ok || bad "S2: the keys file must be consumed by the tick"
grep -q "$P --pending" "$R/gate-calls.log" 2>/dev/null && ok || bad "S1: a split-ready tick must fetch the live fingerprint first (--pending)"

echo "split-chain: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
