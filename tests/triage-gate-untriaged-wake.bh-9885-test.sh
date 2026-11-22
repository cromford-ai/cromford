#!/bin/bash
# tests/triage-gate-untriaged-wake.bh-9885-test.sh — BH-9885: the queue-gates
# brake must not hold a NEW or untriaged ticket.
#
# THE INCIDENT (project-3, 2026-11-21). Three queued tickets waited on two open PRs
# whose state did not move. Every tick from 22:56Z printed
# `SKIP queue-gates-unchanged`, which exits before step 6 (the board diff). Nine
# new tickets (TK-791..799) waited for the 4 h hard recheck.
#
# THE RULE. On the queue-gates SKIP, the gate fetches the live fingerprint and
# asks bin/lib/triage-gate-untriaged.sh which rows are NEW since the consumed
# fingerprint, or MOVED with an empty triageVerdict. Any such row: write
# gate.pending, answer `RUN board-changed`, leave queuefp alone. None, or any
# read that fails: today's SKIP.
#
# Sections: R1-R15 tgu_untriaged_rows on fixture pairs.
#           U1-U4  the REAL bin/triage-gate.sh and bin/gate-diff.sh on a scratch
#                  in-app board, with a stub curl and a stub gh (0 network).
#           K1-K4  the QUEUE_GATE_HARD_RECHECK_S knob.
#
# Run from anywhere: bash tests/triage-gate-untriaged-wake.bh-9885-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1      || { echo "triage-gate-untriaged-wake: jq missing, cannot run" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "triage-gate-untriaged-wake: python3 missing, cannot run" >&2; exit 1; }

# ONE clock read for the file (bin/test-determinism-lint.sh).
NOW=$(date +%s)

# ════════════════════════════════════════════════════════════════════════════
# §R — tgu_untriaged_rows
# ════════════════════════════════════════════════════════════════════════════
LIB="$DIR/bin/lib/triage-gate-untriaged.sh"
mkdir -p "$T/r"
tgu() { # tgu <stored-json-or-@path> <live-json> -> OUT, RC
  local s="$T/r/stored.json" l="$T/r/live.json"
  case "$1" in @*) s="${1#@}" ;; *) printf '%s' "$1" > "$s" ;; esac
  printf '%s' "$2" > "$l"
  RC=0
  OUT=$( [ -r "$LIB" ] || exit 99; . "$LIB"; tgu_untriaged_rows "$s" "$l" ) || RC=$?
}
row() { # row <id> <verdict-json> [commentCount]
  printf '{"id":%s,"status":"todo","waitingOn":"team","triageVerdict":%s,"commentCount":%s,"lastActivityAt":"2026-11-21T22:00:00Z","title":"t%s"}' \
    "$1" "$2" "${3:-0}" "$1"
}
iss() { # iss <number> <state> [comments]
  printf '{"number":%s,"state":"%s","title":"i%s","comments":%s,"updatedAt":"2026-11-21T22:00:00Z"}' "$1" "$2" "$1" "${3:-0}"
}
TAB=$'\t'

# R1 — a new in-app row with no verdict (the project-3 TK-793 case).
tgu "{\"b1\":[$(row 7 '"ready"')]}" "{\"b1\":[$(row 7 '"ready"'),$(row 104 null)]}"
[ "$RC" = 0 ] && [ "$OUT" = "b1${TAB}104" ] && ok || bad "R1: a new unverdicted row must trigger (rc $RC, out: $OUT)"
# R2 — a new row that already has a verdict is still new since the last run.
tgu "{\"b1\":[$(row 7 '"ready"')]}" "{\"b1\":[$(row 7 '"ready"'),$(row 105 '"ready"')]}"
[ "$RC" = 0 ] && [ "$OUT" = "b1${TAB}105" ] && ok || bad "R2: a new verdicted row must trigger (rc $RC, out: $OUT)"
# R3 — moved, verdict null.
tgu "{\"b1\":[$(row 7 null 0)]}" "{\"b1\":[$(row 7 null 1)]}"
[ "$RC" = 0 ] && [ "$OUT" = "b1${TAB}7" ] && ok || bad "R3: a moved null-verdict row must trigger (rc $RC, out: $OUT)"
# R4 — the verdict was cleared.
tgu "{\"b1\":[$(row 7 '"needs_clarification"')]}" "{\"b1\":[$(row 7 null)]}"
[ "$RC" = 0 ] && [ "$OUT" = "b1${TAB}7" ] && ok || bad "R4: a cleared verdict must trigger (rc $RC, out: $OUT)"
# R5 — empty string is no verdict.
tgu "{\"b1\":[$(row 7 '""' 0)]}" "{\"b1\":[$(row 7 '""' 2)]}"
[ "$RC" = 0 ] && [ "$OUT" = "b1${TAB}7" ] && ok || bad "R5: a moved empty-verdict row must trigger (rc $RC, out: $OUT)"
# R6 — a board key the stored fingerprint never had.
tgu "{\"b1\":[$(row 7 '"ready"')]}" "{\"b1\":[$(row 7 '"ready"')],\"b2\":[$(row 9 '"ready"')]}"
[ "$RC" = 0 ] && [ "$OUT" = "b2${TAB}9" ] && ok || bad "R6: a row on a new board key must trigger (rc $RC, out: $OUT)"
# R7 — a new open GitHub issue.
tgu "{\"issues\":[$(iss 5 OPEN)],\"prs\":[]}" "{\"issues\":[$(iss 5 OPEN),$(iss 6 OPEN)],\"prs\":[]}"
[ "$RC" = 0 ] && [ "$OUT" = "issues${TAB}6" ] && ok || bad "R7: a new open issue must trigger (rc $RC, out: $OUT)"
# R8 — nothing moved (Ask 4).
B8="{\"b1\":[$(row 7 '"queued"'),$(row 8 '"queued"')]}"
tgu "$B8" "$B8"
[ "$RC" = 1 ] && [ -z "$OUT" ] && ok || bad "R8: an equal board must answer rc 1 with no rows (rc $RC, out: $OUT)"
# R9 — a static unverdicted row must not buy a session every tick.
tgu "{\"b1\":[$(row 7 null)]}" "{\"b1\":[$(row 7 null)]}"
[ "$RC" = 1 ] && [ -z "$OUT" ] && ok || bad "R9: a byte-equal null-verdict row must not trigger (rc $RC, out: $OUT)"
# R10 — moved, but it has a verdict (near miss).
tgu "{\"b1\":[$(row 7 '"ready"' 0)]}" "{\"b1\":[$(row 7 '"ready"' 1)]}"
[ "$RC" = 1 ] && [ -z "$OUT" ] && ok || bad "R10: a moved verdicted row must not trigger (rc $RC, out: $OUT)"
# R11 — a removed row.
tgu "{\"b1\":[$(row 7 null),$(row 8 null)]}" "{\"b1\":[$(row 7 null)]}"
[ "$RC" = 1 ] && [ -z "$OUT" ] && ok || bad "R11: a removed row must not trigger (rc $RC, out: $OUT)"
# R12 — a GitHub issue moved; it has no triageVerdict field.
tgu "{\"issues\":[$(iss 5 OPEN 0)],\"prs\":[]}" "{\"issues\":[$(iss 5 OPEN 1)],\"prs\":[]}"
[ "$RC" = 1 ] && [ -z "$OUT" ] && ok || bad "R12: a moved issue with no verdict key must not trigger (rc $RC, out: $OUT)"
# R13 — prs and meta are never triggers.
tgu "{\"issues\":[],\"prs\":[{\"number\":12,\"headRefOid\":\"a\",\"state\":\"OPEN\"}],\"meta\":{\"5\":\"x\"}}" \
    "{\"issues\":[],\"prs\":[{\"number\":12,\"headRefOid\":\"b\",\"state\":\"OPEN\"},{\"number\":13,\"headRefOid\":\"c\",\"state\":\"OPEN\"}],\"meta\":{\"5\":\"y\",\"6\":\"z\"}}"
[ "$RC" = 1 ] && [ -z "$OUT" ] && ok || bad "R13: prs/meta moves must not trigger (rc $RC, out: $OUT)"
# R14 — a new CLOSED issue.
tgu "{\"issues\":[],\"prs\":[]}" "{\"issues\":[$(iss 9 CLOSED)],\"prs\":[]}"
[ "$RC" = 1 ] && [ -z "$OUT" ] && ok || bad "R14: a new closed issue must not trigger (rc $RC, out: $OUT)"
# R15 — the stored fingerprint is not JSON, or is missing: rc 2.
tgu "not json" "{\"b1\":[$(row 104 null)]}"
[ "$RC" = 2 ] && [ -z "$OUT" ] && ok || bad "R15: an unparseable stored fp must be rc 2 (rc $RC, out: $OUT)"
tgu "@$T/r/no-such-file" "{\"b1\":[$(row 104 null)]}"
[ "$RC" = 2 ] && [ -z "$OUT" ] && ok || bad "R15: a missing stored fp must be rc 2 (rc $RC, out: $OUT)"

# ════════════════════════════════════════════════════════════════════════════
# §U — the real gate on a scratch in-app board
# ════════════════════════════════════════════════════════════════════════════
H="$T/h"
mkdir -p "$H/bin/lib" "$H/env" "$H/state" "$H/logs" "$H/flags" "$H/fixture" "$H/ctl"
cp "$DIR/bin/triage-gate.sh" "$DIR/bin/gate-diff.sh" "$DIR/bin/board-fetch.sh" "$H/bin/"
# scratch-closure-allow: the gate's full closure (~150 libs) carries lane-gate.sh and the jobs client; this suite needs the gate WITHOUT them so the knob reads env (K1-K4) and no lib reaches a network, as tests/triage-gate-fingerprint-deps.bh-899-test.sh does
for f in board-creds.sh internal-token.sh ready-queue.sh gh-rest.sh gh-rest-var.sh \
         triage-gate-untriaged.sh; do
  [ -r "$DIR/bin/lib/$f" ] && cp "$DIR/bin/lib/$f" "$H/bin/lib/"
done
# lane-gate.sh is NOT copied: with no lib_env_apply the knob is the env value,
# then the code fallback. That is the path K1-K4 pin.
chmod +x "$H/bin/"*.sh

cat > "$H/bin/fleet-conf.sh" <<'EOC'
#!/bin/bash
case "${1:-}" in
  x-os)
    case "${2:-}" in
      repo) echo "example-org/x-os" ;;
      board_prefix|*) echo "/api/board" ;;
    esac ;;
  *) echo "" ;;
esac
EOC
chmod +x "$H/bin/fleet-conf.sh"
printf 'XOS_API_BASE=https://board.example\nXOS_INTERNAL_API_TOKEN=tok-fixture-1\n' > "$H/env/x-os.env"

# curl stand-in: one file per route; a missing file is curl -f's exit 22.
cat > "$H/bin/curl" <<EOC
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
F=""
case "\$URL" in
  */boards/*/tickets) F="$H/fixture/tickets.json" ;;
  */boards)           F="$H/fixture/boards.json" ;;
esac
[ -n "\$F" ] && [ -f "\$F" ] || exit 22
if [ -n "\$OUT" ]; then cat "\$F" > "\$OUT"; else cat "\$F"; fi
exit 0
EOC
chmod +x "$H/bin/curl"

# gh stand-in: `gh api -i repos/<slug>/pulls/<n>` answers that PR open. Every
# call is counted, so the suite can prove the PR-state read really ran.
cat > "$H/bin/gh" <<EOC
#!/bin/bash
echo "\$*" >> "$H/gh-argv"
[ "\${1:-}" = api ] || exit 1
shift; inc=0; path=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    -i) inc=1; shift ;;
    -X|-f|-F|-H) shift 2 ;;
    -*) shift ;;
    *) path="\$1"; shift; break ;;
  esac
done
case "\$path" in
  repos/*/pulls/[0-9]*)
    n=\${path##*/}
    [ "\$inc" = 1 ] && printf 'HTTP/2.0 200\r\ncontent-type: application/json\r\n\r\n'
    printf '{"number":%s,"state":"open","merged_at":null}\n' "\$n"; exit 0 ;;
esac
exit 1
EOC
chmod +x "$H/bin/gh"

export HARNESS="$H"
export PATH="$H/bin:$PATH"
unset QUEUE_GATE_HARD_RECHECK_S

GATE="$H/state/x-os.gate.json"
PENDING="$H/state/x-os.gate.pending"
QFPF="$H/state/x-os.queuefp"
printf '[{"id":"b1","name":"Product Board","keyPrefix":"TK"}]\n' > "$H/fixture/boards.json"

board() { # board <row>... -> tickets.json
  local IFS=,
  printf '{"tickets":[%s]}\n' "$*" > "$H/fixture/tickets.json"
}
Q3=("$(row 101 '"queued"')" "$(row 102 '"queued"')" "$(row 103 '"queued"')")
age_back() { # put the queuefp stamp inside the PR-gate window
  awk -v s="$((NOW - ${1:-3000}))" 'NR==2{print s; next}{print}' "$QFPF" > "$QFPF.n" && mv -f "$QFPF.n" "$QFPF"
}
tick() { OUT=$(bash "$H/bin/triage-gate.sh" x-os 2>/dev/null); }

# u_setup [extra-row...] — 3 queued tickets waiting on two open PRs, the gate
# seeded, and the queue brake walked to `SKIP queue-gates-unchanged`.
u_setup() {
  rm -f "$GATE" "$PENDING" "$QFPF" "$H/state/x-os.gate-meta" "$H/gh-argv"
  printf 'TK-101 101 — waiting on PR #1267 project=x-os\nFR-102 102 — waiting on PR #1280 project=x-os\nFR-103 103 — waiting on PR #1267 project=x-os\n' \
    > "$H/logs/READY-QUEUE.log"
  board "${Q3[@]}" "$@"
  bash "$H/bin/triage-gate.sh" x-os --seed >/dev/null 2>&1
  tick
  grep -q '^RUN queue-pending' <<<"$OUT" || bad "setup: tick 1 must RUN queue-pending (got: $OUT)"
  age_back; tick
  grep -q '^RUN queue-pending' <<<"$OUT" || bad "setup: tick 2 must store the PR vector (got: $OUT)"
  age_back; tick
  grep -q '^SKIP queue-gates-unchanged' <<<"$OUT" || bad "setup: tick 3 must SKIP queue-gates-unchanged (got: $OUT)"
  [ "$(wc -l < "$QFPF")" = 3 ] || bad "setup: queuefp must hold the 3-line PR vector"
  QFP_BEFORE=$(cat "$QFPF")
}

# U1 (Ask 3) — a new untriaged ticket opens the gate, and only it is scoped.
u_setup
[ -s "$GATE" ] && ok || bad "U1: --seed wrote no gate.json"
grep -q 'pulls/1267' "$H/gh-argv" 2>/dev/null && ok || bad "U1: the PR-state read never ran"
board "${Q3[@]}" "$(row 104 null)"
tick
[ "$OUT" = "RUN board-changed" ] && ok || bad "U1: a new untriaged ticket must RUN board-changed (got: $OUT)"
[ -s "$PENDING" ] && ok || bad "U1: gate.pending must be written for the scope arm"
[ "$(cat "$QFPF")" = "$QFP_BEFORE" ] && ok || bad "U1: queuefp must be byte-unchanged"
DIFF=$(bash "$H/bin/gate-diff.sh" x-os 2>/dev/null); DRC=$?
[ "$DRC" = 0 ] && ok || bad "U1: gate-diff.sh must exit 0 (rc $DRC)"
[ "$(grep -c . <<<"$DIFF")" = 1 ] && grep -qE 'NEW 104( |$)' <<<"$DIFF" && ok \
  || bad "U1: the scope must name exactly the new ticket 104: $DIFF"
grep -qE ' 10[123]( |$)' <<<"$DIFF" && bad "U1: a queued ticket reached the scope: $DIFF" || ok

# U2 (Ask 4) — no new ticket: still SKIP, nothing written.
u_setup
tick
grep -q '^SKIP queue-gates-unchanged (1267,1280 all same state; hard recheck in ' <<<"$OUT" && ok \
  || bad "U2: an unchanged board must SKIP queue-gates-unchanged (got: $OUT)"
[ ! -e "$PENDING" ] && ok || bad "U2: SKIP must leave no gate.pending"
[ "$(cat "$QFPF")" = "$QFP_BEFORE" ] && ok || bad "U2: queuefp must be byte-unchanged"

# U3 — an unverdicted ticket that did not move does not loop.
u_setup "$(row 105 null)"
tick
grep -q '^SKIP queue-gates-unchanged' <<<"$OUT" && ok || bad "U3: a static null-verdict ticket must SKIP (got: $OUT)"
[ ! -e "$PENDING" ] && ok || bad "U3: SKIP must leave no gate.pending"

# U4 — the board read fails on the trigger tick: today's SKIP, no spend.
u_setup
board "${Q3[@]}" "$(row 104 null)"
rm -f "$H/fixture/tickets.json"
tick
grep -q '^SKIP queue-gates-unchanged' <<<"$OUT" && ok || bad "U4: a failed board read must keep the SKIP (got: $OUT)"
[ ! -e "$PENDING" ] && ok || bad "U4: a failed read must leave no gate.pending"
[ "$(cat "$QFPF")" = "$QFP_BEFORE" ] && ok || bad "U4: queuefp must be byte-unchanged"

# ════════════════════════════════════════════════════════════════════════════
# §K — QUEUE_GATE_HARD_RECHECK_S
# ════════════════════════════════════════════════════════════════════════════
# The queue-gates SKIP names the minutes left: (knob - age) / 60. queuefp is
# aged 3000 s by age_back, so the fallback 14400 prints 190m.
mins() { sed -nE 's/.*hard recheck in (-?[0-9]+)m.*/\1/p' <<<"$OUT"; }
# The K ticks run the gate on a pinned clock: `date +%s` answers the suite's
# NOW, the same value age_back stamps from, so the minutes figure is exact on
# any machine speed (the U section above can take minutes on a slow runner).
# Every other `date` call goes to the real binary.
REAL_DATE=$(command -v date)
mkdir -p "$T/kclock"
cat > "$T/kclock/date" <<EOC
#!/bin/bash
[ "\$#" = 1 ] && [ "\$1" = "+%s" ] && { echo $NOW; exit 0; }
exec $REAL_DATE "\$@"
EOC
chmod +x "$T/kclock/date"
ktick() { OUT=$(PATH="$T/kclock:$PATH" bash "$H/bin/triage-gate.sh" x-os 2>/dev/null); }

# K1 — no env, no row: 14400.
u_setup
age_back 2970; ktick
[ "$(mins)" = 190 ] && ok || bad "K1: no knob must read 14400 (190m left at age 2970 s; got: $OUT)"

# K2 — 3000: a queuefp aged 3100 s is past the hard recheck.
u_setup
age_back 3100
QUEUE_GATE_HARD_RECHECK_S=3000 ktick
[ "$OUT" = "RUN queue-pending" ] && ok || bad "K2: knob 3000 at age 3100 s must RUN queue-pending (got: $OUT)"
# …and inside it the minutes text uses the knob.
u_setup
age_back 2800
QUEUE_GATE_HARD_RECHECK_S=3000 ktick
grep -q '^SKIP queue-gates-unchanged' <<<"$OUT" && [ "$(mins)" = 3 ] && ok \
  || bad "K2: knob 3000 at age 2800 s must SKIP with 3m left (got: $OUT)"

# K3 — junk falls back to 14400.
u_setup
age_back 2970
QUEUE_GATE_HARD_RECHECK_S=abc ktick
[ "$(mins)" = 190 ] && ok || bad "K3: junk must read 14400 (got: $OUT)"

# K4 — under the 2700 minimum falls back to 14400.
u_setup
age_back 2970
QUEUE_GATE_HARD_RECHECK_S=1000 ktick
[ "$(mins)" = 190 ] && ok || bad "K4: 1000 (under 2700) must read 14400 (got: $OUT)"

# The registry declares the knob with the code fallback as its default.
REG="$DIR/catalog/lanes.d/_lib.triage-gate.json"
[ "$(jq -r '.libs[] | select(.id=="triage-gate") | .knobs[] | select(.env=="QUEUE_GATE_HARD_RECHECK_S") | "\(.default) \(.min)"' "$REG" 2>/dev/null)" = "14400 2700" ] \
  && ok || bad "K: catalog/lanes.d/_lib.triage-gate.json must declare QUEUE_GATE_HARD_RECHECK_S default 14400 min 2700"

echo "triage-gate-untriaged-wake: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
