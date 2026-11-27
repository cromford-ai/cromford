#!/bin/bash
# tests/fixround-timeout-budget.bh-10057-test.sh — BH-10057 (slice C0, item 5):
# the resolver ladder. A fix round that BH-9404 retries after a timeout (agent
# rc 124) runs with a LARGER agent budget, the round bound admits that budget
# (the claim's stale cutoff stays A + V + M), and every ladder class buys at least 2 fix
# rounds. (The ticket names this suite tests/resolver-ladder-timeout-test.sh;
# the per-ticket rule names it here.)
#
#   F0      the lib and the fragment exist and parse
#   U1-U10  frb_pct / frb_retry_s / frb_agent_max, the decision table
#   B1-B9   brtb_agent_timeout over a real record file (the retry matcher)
#   R1-R5   the REAL bin/blocked-resolver.sh --fix-here with a stub agent-call
#           that records its timeout argument and its parent `timeout` argv
#   S1-S4   frc_bound (bin/fix-round-claim.sh) and the claim's stale_min
#   H1-H2   br_fix_bound and br_fix_stale_claim (bin/lib/br/cap.sh)
#   K1-K4   the knob rows; L1-L2 every ladder class buys 2 fix rounds
#   C1      one call site in the driver
# No vendor is called: the agent-call is a stub, gh is the fixture's fake.
# Run: HARNESS_TEST_SANDBOX=1 bash tests/fixround-timeout-budget.bh-10057-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "FAIL: jq missing"; exit 1; }
LIB="$DIR/bin/lib/fix-retry-budget.sh"
FRAG="$DIR/bin/blocked-resolver.d/bh-10057-timeout-budget.sh"
DRIVER="$DIR/bin/blocked-resolver.sh"
KNOB="$DIR/catalog/lanes.d/blocked-resolver.knobs.d/BR_FIX_TIMEOUT_RETRY_PCT.json"
export GIT_CONFIG_NOSYSTEM=1
lift() { awk -v n="$1" '$0 ~ "^"n"\\(\\) \\{" {f=1} f{print} f&&/^}/{exit}' "$2"; }
H1=1111111111111111111111111111111111111111
H2=2222222222222222222222222222222222222222

# ---- F0 ----------------------------------------------------------------------
[ -f "$LIB" ] && bash -n "$LIB" && ok || bad "F0 bin/lib/fix-retry-budget.sh is missing or does not parse"
[ -f "$FRAG" ] && bash -n "$FRAG" && ok || bad "F0 bin/blocked-resolver.d/bh-10057-timeout-budget.sh is missing or does not parse"

# ---- U: the pure lib -----------------------------------------------------------
LF() { bash -c '. "$1" 2>/dev/null || exit 9; shift; "$@"; echo " rc=$?"' _ "$LIB" "$@" 2>/dev/null; }
[ "$(LF frb_pct 150)" = "150 rc=0" ] && ok || bad "U1 frb_pct 150: $(LF frb_pct 150)"
[ "$(LF frb_pct 110)" = "110 rc=0" ] && ok || bad "U2 frb_pct 110: $(LF frb_pct 110)"
[ "$(LF frb_pct 400)" = "400 rc=0" ] && ok || bad "U3 frb_pct 400: $(LF frb_pct 400)"
[ "$(LF frb_pct 100)" = "110 rc=0" ] && ok || bad "U4 frb_pct 100 clamps to 110: $(LF frb_pct 100)"
[ "$(LF frb_pct 0)" = "110 rc=0" ] && ok || bad "U5 frb_pct 0 clamps to 110: $(LF frb_pct 0)"
[ "$(LF frb_pct 999)" = "400 rc=0" ] && ok || bad "U6 frb_pct 999 clamps to 400: $(LF frb_pct 999)"
for j in abc 1.5 -1; do
  [ "$(LF frb_pct "$j")" = "150 rc=3" ] && ok || bad "U7-U9 frb_pct '$j' is the fallback 150 with rc 3: $(LF frb_pct "$j")"
done
[ "$(LF frb_pct "")" = "150 rc=0" ] && ok || bad "U10 frb_pct '' (no row) is the fallback 150, rc 0: $(LF frb_pct "")"
[ "$(LF frb_retry_s 3600 150)" = "5400 rc=0" ] && ok || bad "U frb_retry_s 3600 150: $(LF frb_retry_s 3600 150)"
[ "$(LF frb_retry_s x 150)" = " rc=1" ] && ok || bad "U frb_retry_s x: rc 1, nothing printed: $(LF frb_retry_s x 150)"
[ "$(LF frb_agent_max 3600 1 150)" = "5400 rc=0" ] && ok || bad "U frb_agent_max retries 1: $(LF frb_agent_max 3600 1 150)"
[ "$(LF frb_agent_max 3600 0 150)" = "3600 rc=0" ] && ok || bad "U frb_agent_max retries 0: $(LF frb_agent_max 3600 0 150)"
[ "$(LF frb_agent_max 3600 junk 150)" = "5400 rc=0" ] && ok || bad "U frb_agent_max junk retries reads as the writer's fallback 1: $(LF frb_agent_max 3600 junk 150)"
[ "$(LF frb_agent_max nope 1 150)" = " rc=1" ] && ok || bad "U frb_agent_max bad base: rc 1: $(LF frb_agent_max nope 1 150)"

# ---- B: brtb_agent_timeout over a real record file ---------------------------
U="$T/u"; mkdir -p "$U/rec" "$U/bin/lib"
[ -f "$LIB" ] && cp "$LIB" "$U/bin/lib/"
cat > "$U/stubs.sh" <<EOF
H="$U"; FIX_AGENT_TIMEOUT=3600
say() { printf '%s\n' "\$*" >> "$U/say.log"; }
br_load() { [ -f "$U/rec-bad" ] && return 1; cat "$U/rec/\$2.json" 2>/dev/null || echo '{}'; }
br_json_edit() { local f="$U/rec/\$2.json" filter="\$3" cur; shift 3
  [ -f "$U/rec-ro" ] && return 1
  cur=\$(br_load tproj "\${f##*/}" | jq -c "\$@" "\$filter") || return 1; printf '%s\n' "\$cur" > "\$f"; }
EOF
BT() { # BT <record-json> <head> [env...] — brtb_agent_timeout; prints the answer
  local rec="$1" head="$2"; shift 2
  printf '%s\n' "$rec" > "$U/rec/b.json"; : > "$U/say.log"
  BT2 "$head" "$@"
}
BT2() { # BT2 <head> [env...] — brtb_agent_timeout on the record file as it is now
  local head="$1"; shift
  ( unset BR_FIX_TIMEOUT_RETRIES BR_FIX_TIMEOUT_RETRY_PCT; for e in "$@"; do export "${e?}"; done
    bash -c '. "$1"; . "$2" 2>/dev/null || exit 9; brtb_agent_timeout tproj b "$3"' _ "$U/stubs.sh" "$FRAG" "$head" 2>/dev/null )
}
M() { jq -nc --args '{timeout_retry: $ARGS.positional}' "$@"; }
[ "$(BT "$(M "$H1")" "$H1")" = 5400 ] && ok || bad "B1 mark H1, head H1: 5400 (got $(BT "$(M "$H1")" "$H1"))"
grep -q 'timeout retry: agent budget 5400s (150% of 3600s)' "$U/say.log" && ok || bad "B1 one say line: $(cat "$U/say.log")"
HU=$(printf 'ABCDEF%034d' 0); HL=$(printf '%s' "$HU" | tr 'A-F' 'a-f')
[ "$(BT "$(M "$HL")" "$HU")" = 5400 ] && ok || bad "B2 an upper-case head matches its lower-case mark: $(BT "$(M "$HL")" "$HU")"
[ "$(BT "$(M -)" "")" = 5400 ] && ok || bad "B3 head unknown, mark '-': 5400"
[ "$(BT "$(M "$H1" "$H1")" "$H1")" = 5400 ] && ok || bad "B4 two marks: still 5400, not 2x: $(BT "$(M "$H1" "$H1")" "$H1")"
[ "$(BT '{}' "$H1")" = 3600 ] && ok || bad "B5 no timeout_retry field: 3600"
[ ! -s "$U/say.log" ] && ok || bad "B5 no budget line on a first round: $(cat "$U/say.log")"
[ "$(BT "$(M "$H2")" "$H1")" = 3600 ] && ok || bad "B6 mark H2, head H1: 3600"
[ "$(BT "$(M "${H1:0:8}")" "$H1")" = 3600 ] && ok || bad "B7 a prefix mark is no match: 3600"
touch "$U/rec-bad"
[ "$(BT "$(M "$H1")" "$H1")" = 3600 ] && ok || bad "B8 an unreadable record: the base 3600"
rm -f "$U/rec-bad"
[ "$(BT "$(M "$H1")" "$H1" BR_FIX_TIMEOUT_RETRIES=0)" = 3600 ] && ok || bad "B9 BR_FIX_TIMEOUT_RETRIES=0: 3600"
# B10-B13 — one retry per mark: the round that gets the budget spends it
[ "$(BT "$(M "$H1")" "$H1")" = 5400 ] && [ "$(jq -c '.timeout_retry_ran' "$U/rec/b.json")" = "[\"$H1\"]" ] \
  && ok || bad "B10 the retry round records its head in .timeout_retry_ran: $(cat "$U/rec/b.json")"
: > "$U/say.log"
[ "$(BT2 "$H1")" = 3600 ] && ok || bad "B11 a later round on the same head (mark spent): 3600 (got $(BT2 "$H1"))"
grep -q 'timeout retry: agent budget' "$U/say.log" && bad "B11 no budget line once the mark is spent" || ok
[ "$(BT "$(jq -nc --arg h "$H1" '{timeout_retry:[$h,$h], timeout_retry_ran:[$h]}')" "$H1")" = 5400 ] \
  && ok || bad "B12 two marks, one spent: the second retry gets 5400"
[ "$(BT "$(jq -nc --arg h "$H2" --arg g "$H1" '{timeout_retry:[$g], timeout_retry_ran:[$h]}')" "$H1")" = 5400 ] \
  && ok || bad "B12 a spent mark of another head does not count"
touch "$U/rec-ro"
[ "$(BT "$(M "$H1")" "$H1")" = 3600 ] && grep -q 'could not be recorded as spent' "$U/say.log" \
  && ok || bad "B13 the spend write fails: the base 3600 and one line: $(cat "$U/say.log")"
rm -f "$U/rec-ro"
[ "$(BT "$(M "$H1")" "$H1" BR_FIX_TIMEOUT_RETRY_PCT=200)" = 7200 ] && ok || bad "B pct 200: 7200"
[ "$(BT "$(M "$H1")" "$H1" BR_FIX_TIMEOUT_RETRY_PCT=x)" = 5400 ] && grep -q "BR_FIX_TIMEOUT_RETRY_PCT is 'x'" "$U/say.log" \
  && ok || bad "B a junk pct: the fallback 150 and one line: $(cat "$U/say.log")"

# ---- S: frc_bound (bin/fix-round-claim.sh) and the claim's stale_min --------------
lift frc_bound "$DIR/bin/fix-round-claim.sh" > "$T/frc_bound.sh"
SB() { # SB [env...] — prints "<FRC_T> <stale_min>"
  ( unset BR_FIX_AGENT_TIMEOUT BR_FIX_VERIFY_TIMEOUT BR_FIX_HOP_MARGIN BR_FIX_LANE_TIMEOUT BR_FIX_TIMEOUT_RETRIES BR_FIX_TIMEOUT_RETRY_PCT
    export BR_FIX_AGENT_TIMEOUT=3600 BR_FIX_VERIFY_TIMEOUT=2700 BR_FIX_HOP_MARGIN=300 BR_FIX_LANE_TIMEOUT=5400
    for e in "$@"; do export "${e?}"; done
    bash -c 'lane_knob() { local v="${!2:-}"; printf "%s" "$v"; }; . "$1" 2>/dev/null; . "$2"; frc_bound
      s=""; [ -n "$FRC_STALE_S" ] && s=$(( (FRC_STALE_S + 59) / 60 )); echo "$FRC_T $s"' _ "$LIB" "$T/frc_bound.sh" 2>/dev/null )
}
# The round bound admits the retry; the stale cutoff stays A + V + M (110), so a
# dead claim is re-offered as soon as before (BH-10115 F4 pins a 120-minute
# re-offer). A re-offer of a live retry runs nothing: the round holds its key lock.
[ "$(SB)" = "8400 110" ] && ok || bad "S1 defaults: round bound 8400, stale_min 110 (got $(SB))"
[ "$(SB BR_FIX_TIMEOUT_RETRIES=0)" = "6600 110" ] && ok || bad "S2 retries off: A + V + M, 6600 / 110 (got $(SB BR_FIX_TIMEOUT_RETRIES=0))"
[ "$(SB BR_FIX_TIMEOUT_RETRY_PCT=junk)" = "8400 110" ] && ok || bad "S3 junk pct: the fallback 150, 8400 / 110 (got $(SB BR_FIX_TIMEOUT_RETRY_PCT=junk))"
[ "$(SB BR_FIX_TIMEOUT_RETRY_PCT=200)" = "10200 110" ] && ok || bad "S3b pct 200: round bound 10200, the cutoff stays 110 (got $(SB BR_FIX_TIMEOUT_RETRY_PCT=200))"
[ "$(SB BR_FIX_AGENT_TIMEOUT=junk)" = "5400 95" ] && ok || bad "S4 junk agent knob: the LANE fallback 5400, cutoff 5700 (got $(SB BR_FIX_AGENT_TIMEOUT=junk))"

# ---- H: br_fix_bound and br_fix_stale_claim (bin/lib/br/cap.sh) ---------------------
lift br_fix_bound "$DIR/bin/lib/br/cap.sh" > "$T/cap.sh"
lift br_fix_stale_claim "$DIR/bin/lib/br/cap.sh" >> "$T/cap.sh"
mkdir -p "$U/hb/bin"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/alerts.log"\n' "$U/hb" > "$U/hb/bin/lane-alert.sh"; chmod +x "$U/hb/bin/lane-alert.sh"
HB() { # HB <fn> [args...] [-- env...]
  local a=() e=() x seen=0
  for x in "$@"; do if [ "$x" = -- ]; then seen=1; elif [ "$seen" = 1 ]; then e+=("$x"); else a+=("$x"); fi; done
  ( unset BR_FIX_TIMEOUT_RETRIES BR_FIX_TIMEOUT_RETRY_PCT; for kv in ${e[@]+"${e[@]}"}; do export "${kv?}"; done
    bash -c 'H="$1"; LOG=/dev/null; say() { :; }; FIX_AGENT_TIMEOUT=3600 FIX_VERIFY_TIMEOUT=2700 FIX_HOP_MARGIN=300 FIX_LANE_TIMEOUT=5400
      cp -r "$2/bin/lib" "$H/bin/" 2>/dev/null; . "$3" 2>/dev/null; . "$4"; shift 4; "$@"' _ "$U/hb" "$U" "$FRAG" "$T/cap.sh" ${a[@]+"${a[@]}"} 2>/dev/null )
}
[ "$(HB br_fix_bound)" = 8400 ] && ok || bad "H1 br_fix_bound with the fragment: 8400 (got $(HB br_fix_bound))"
[ "$(HB br_fix_bound -- BR_FIX_TIMEOUT_RETRIES=0)" = 6600 ] && ok || bad "H1 retries off: 6600 (got $(HB br_fix_bound -- BR_FIX_TIMEOUT_RETRIES=0))"
ROWAT() { jq -nc --arg u "$(date -u -d "-$1 seconds" +%Y-%m-%dT%H:%M:%SZ)" '{id:7, claimed_by:"box-a", updated_at:$u}'; }
: > "$U/hb/alerts.log"; HB br_fix_stale_claim tproj TK-1 ck "$(ROWAT 7000)" >/dev/null
[ ! -s "$U/hb/alerts.log" ] && ok || bad "H2 a claim 7000 s old (a live retry) is not paged: $(cat "$U/hb/alerts.log")"
: > "$U/hb/alerts.log"; HB br_fix_stale_claim tproj TK-1 ck "$(ROWAT 8500)" >/dev/null
grep -q -- '--id fix-round-stale-claim-tproj-ck .*over 8400s' "$U/hb/alerts.log" && ok || bad "H2 a claim 8500 s old pages with the 8400 s bound: $(cat "$U/hb/alerts.log")"

# ---- K: the knob rows; L: every ladder class buys 2 fix rounds -----------------------
jq -e '.env == "BR_FIX_TIMEOUT_RETRY_PCT" and .type == "int" and .default == 150 and .min == 110 and .min > 100 and .max == 400' "$KNOB" >/dev/null 2>&1 \
  && ok || bad "K1 the BR_FIX_TIMEOUT_RETRY_PCT row: default 150, min 110, max 400"
grep -q 'lane.blocked-resolver.BR_FIX_TIMEOUT_RETRY_PCT' "$LIB" 2>/dev/null && ok || bad "K1 the lib names the row of its fallback"
# K4 — the lib's clamp is the row's min and max (one value, two places: this pins them together)
KMIN=$(jq -r .min "$KNOB" 2>/dev/null); KMAX=$(jq -r .max "$KNOB" 2>/dev/null); KDEF=$(jq -r .default "$KNOB" 2>/dev/null)
[ "$(LF frb_pct 0)" = "$KMIN rc=0" ] && [ "$(LF frb_pct 99999)" = "$KMAX rc=0" ] && [ "$(LF frb_pct "")" = "$KDEF rc=0" ] \
  && ok || bad "K4 frb_pct clamps to the row's min $KMIN / max $KMAX and falls back to its default $KDEF: $(LF frb_pct 0) / $(LF frb_pct 99999) / $(LF frb_pct "")"
( cd "$DIR" && HARNESS_TEST_SANDBOX=1 bin/lanes-build.sh --check >/dev/null 2>&1 ) && ok || bad "K2 bin/lanes-build.sh --check"
MF=$(jq '.knobs[] | select(.env == "BR_MAX_FIXROUNDS") | .default' "$DIR/catalog/lanes.d/blocked-resolver.json" 2>/dev/null)
[ "$MF" = 2 ] && ok || bad "K3 the registry default of BR_MAX_FIXROUNDS is 2 (got $MF)"
for fn in br_num br_shape br_fix_cap; do lift "$fn" "$DIR/bin/lib/br/record.sh"; done > "$T/fixcap.sh"
for fn in br_skips_mechanical br_ladder_rung; do lift "$fn" "$DIR/bin/lib/br/ladder.sh"; done > "$T/ladder.sh"
FC() { # FC <record> <reason> — br_fix_cap with the registry default
  ( unset MAX_FIXROUNDS MAX_FIXROUNDS_SMALL BR_CONFLICT_FIX_ROUNDS BR_MAX_FIXROUNDS_SMALL
    export BR_MAX_FIXROUNDS="$MF" BR_REVIEW_FIX_ROUNDS=2
    bash -c '. "$1"; br_fix_cap "$2" "$3" tproj' _ "$T/fixcap.sh" "$1" "$2" 2>/dev/null )
}
for c in 'rebase-gate-red|{"conflict_lines":900}' 'red-ci-twice|{}' 'orphaned-child|{}' 'prequeue-red|{}' \
         'conflict-unresolvable|{"conflict_lines":40}' 'review-changes-requested|{}'; do
  r=${c%%|*}; rec=${c#*|}
  v=$(FC "$rec" "$r")
  [ "${v:-0}" -ge 2 ] 2>/dev/null && ok || bad "L1 $r buys at least 2 fix rounds at the registry default (got '$v')"
done
LR() { bash -c '. "$1"; shift; br_ladder_rung "$@"' _ "$T/ladder.sh" "$@" 2>/dev/null; }
[ "$(LR ci-red 1 1 2)" = fix-round ] && ok || bad "L2 cap 2, one round spent: fix-round (got $(LR ci-red 1 1 2))"
[ "$(LR ci-red 1 2 2)" = rebuild-fresh ] && ok || bad "L2 cap 2, two spent: rebuild-fresh"
[ "$(LR ci-red 1 1 1)" = rebuild-fresh ] && ok || bad "L2 near miss, the old cap 1: rebuild-fresh"
FCB=$(FC '{}' red-ci-twice); [ "$(LR ci-red 1 1 "$FCB")" = fix-round ] && ok || bad "L2 the registry cap ($FCB) buys a second round"

# ---- C1: one call site, before the agent call -----------------------------------------
SITE=$(lift br_fix_round "$DRIVER")
[ "$(grep -c 'brtb_agent_timeout "' "$DRIVER")" = 1 ] && [ "$(printf '%s\n' "$SITE" | grep -c 'brtb_agent_timeout "')" = 1 ] \
  && ok || bad "C1 the driver has exactly one brtb_agent_timeout call line, in br_fix_round"
LB=$(printf '%s\n' "$SITE" | grep -n 'brtb_agent_timeout "' | cut -d: -f1)
LA=$(printf '%s\n' "$SITE" | grep -n 'bin/agent-call.sh" execute' | cut -d: -f1 | head -1)
[ -n "$LB" ] && [ -n "$LA" ] && [ "$LB" -lt "$LA" ] && ok || bad "C1 the call is before the agent call (${LB:-none} < ${LA:-none})"
grep -q '"\$FIX_AGENT_TIMEOUT" "\$H/bin/agent-call.sh"' "$DRIVER" && bad "C1 no agent call keeps the bare FIX_AGENT_TIMEOUT" || ok

# ---- R: the REAL driver, --fix-here -----------------------------------------------------
. "$DIR/tests/lib/fixture-harness.sh" || exit 1
H="$T/h"
mkdir -p "$H/bin"
cp "$DIR/bin/blocked-resolver.sh" "$DIR/bin/fly-pool.sh" "$DIR/bin/merge-sweep.sh" \
   "$DIR/bin/merge-conductor.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/project-of.sh" \
   "$DIR/bin/box-for.sh" "$H/bin/" || exit 1
fx_br_harness "$DIR" "$T" || exit 1
for lib in bin/lib/hub-box.sh bin/lib/heartbeat.sh bin/lib/lane-gate.sh; do
  scratch_install_closure "$lib" "$H" >/dev/null || { echo "FAIL: closure of $lib"; exit 1; }
done
scratch_install_closure bin/blocked-resolver.d/bh-9404-timeout-retry.sh "$H" >/dev/null || { echo "FAIL: closure of the bh-9404 fragment"; exit 1; }
if [ -f "$FRAG" ]; then
  scratch_install_closure bin/blocked-resolver.d/bh-10057-timeout-budget.sh "$H" >/dev/null || { echo "FAIL: closure of the fragment"; exit 1; }
  scratch_install_closure bin/lib/fix-retry-budget.sh "$H" >/dev/null || { echo "FAIL: closure of the lib"; exit 1; }
fi
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
mrs_fixture "$H" tproj
fx_br_ladder_git "$DIR" "$T" || exit 1
git -C "$T/repos/tproj" fetch -q origin
# The "agent": records its timeout argument ($4) and the argv of its parent
# (the `timeout` that bounds it), then exits with the rc the suite wrote.
cat > "$H/bin/agent-call.sh" <<AGENT
#!/bin/bash
printf 'agent=%s\n' "\$4" >> "$T/agent.txt"
printf 'outer=%s\n' "\$(tr '\0' ' ' < /proc/\$PPID/cmdline 2>/dev/null)" >> "$T/agent.txt"
exit "\$(cat "$T/agent-rc" 2>/dev/null || echo 0)"
AGENT
chmod +x "$H/bin/agent-call.sh"
PR="https://github.com/o/tproj/pull/91"
LOGF="$H/logs/blocked-resolver.log"
CK=tb-1
FIXHERE() { # FIXHERE <reason> [env...] — BR_MAX_FIXROUNDS=1 unless an env sets it
  local reason="$1"; shift
  ( unset BR_FIX_TIMEOUT_RETRY_PCT; export BR_MAX_FIXROUNDS=1; for e in "$@"; do export "${e?}"; done
    HARNESS="$H" FLEET_CONF="$H/fleet.conf" REPOS_ROOT="$T/repos" BOX_NAME=box-tproj \
      bash "$H/bin/blocked-resolver.sh" --fix-here tproj "$CK" "$reason" "$PR" - - < "$T/rec-in.json" ) > "$T/fh.out" 2>>"$T/run.log"
  sed -n 's/^FIX_RECORD //p' "$T/fh.out" | base64 -d > "$T/rec-out.json" 2>/dev/null
}
RESET() { # RESET <branch> <agent-rc> <record-jq-filter>
  scratch_rm "$H/state/blocked-resolver"; scratch_rm "$H/tmp/brfix"
  : > "$LOGF"; : > "$T/agent.txt"; : > "$T/comments.txt"
  rm -f "$T/fh.out" "$T/rec-out.json"
  git -C "$T/repos/tproj" worktree prune >/dev/null 2>&1
  git -C "$T/repos/tproj" for-each-ref --format='%(refname:short)' refs/heads/brfix/ \
    | while read -r b; do git -C "$T/repos/tproj" branch -D "$b" >/dev/null 2>&1; done
  printf '%s\n' "$1" > "$T/prbranch"; osha "$1" | tr -d '\n' > "$T/prhead"; printf 'main\n' > "$T/prbase"
  printf '%s' "$2" > "$T/agent-rc"
  jq -nc --arg k "$CK" --arg h "$(osha "$1" | tr -d '\n')" \
    "{project:\"tproj\",rkey:\$k,fixrounds:0,rebuilds:0,mechanicals:1,outcome:\"\",attempts:[]} | $3" > "$T/rec-in.json"
}
AGT() { sed -n 's/^agent=//p' "$T/agent.txt" | tail -1; }
OUTER() { sed -n 's/^outer=//p' "$T/agent.txt" | tail -1; }

# R1 — a head carrying a timeout_retry mark: the agent gets 5400 s
RESET ticket/TK-90 1 '.timeout_retry = [$h]'
FIXHERE red-ci-twice
[ "$(AGT)" = 5400 ] && ok || bad "R1 a marked head: agent-call gets 5400 (got '$(AGT)'; log: $(tail -3 "$LOGF"))"
case "$(OUTER)" in *"timeout -k 60 5400 "*) ok ;; *) bad "R1 the outer timeout is 5400: '$(OUTER)'" ;; esac
grep -q 'timeout retry: agent budget 5400s (150% of 3600s)' "$LOGF" && ok || bad "R1 the log has the budget line: $(grep -i budget "$LOGF" | tail -2)"

# R2 — no mark: the old 3600 s, no budget line
RESET ticket/TK-90 1 '.'
FIXHERE red-ci-twice
[ "$(AGT)" = 3600 ] && ok || bad "R2 no mark: agent-call gets 3600 (got '$(AGT)')"
grep -q 'timeout retry: agent budget' "$LOGF" && bad "R2 no budget line on a first round" || ok

# R3 — BR_FIX_TIMEOUT_RETRY_PCT=200: 7200 s
RESET ticket/TK-90 1 '.timeout_retry = [$h]'
FIXHERE red-ci-twice BR_FIX_TIMEOUT_RETRY_PCT=200
[ "$(AGT)" = 7200 ] && ok || bad "R3 pct 200: agent-call gets 7200 (got '$(AGT)')"

# R4 — round trip: the REAL brtr_take writes the mark on a 124 round, the
# next --fix-here reads it.
RESET ticket/TK-90 124 '.'
FIXHERE red-ci-twice
[ "$(AGT)" = 3600 ] && ok || bad "R4 the first round runs with 3600 (got '$(AGT)')"
[ "$(jq -r '.timeout_retry | length' "$T/rec-out.json" 2>/dev/null)" = 1 ] && ok || bad "R4 brtr_take wrote the mark: $(cat "$T/rec-out.json" 2>/dev/null | head -c 300)"
cp "$T/rec-out.json" "$T/rec-in.json"; : > "$T/agent.txt"
FIXHERE red-ci-twice
[ "$(AGT)" = 5400 ] && ok || bad "R4 the retry round runs with 5400 (got '$(AGT)'; log: $(tail -3 "$LOGF"))"

# R5 — the registry default cap 2: a 124 on round 1 (rounds remain) takes the
# timeout retry too, so round 1 is refunded and the next round gets 5400. A
# third round on the same head, after the retry was spent, gets 3600 again.
RESET ticket/TK-90 124 '.'
FIXHERE red-ci-twice BR_MAX_FIXROUNDS=2
[ "$(AGT)" = 3600 ] && ok || bad "R5 round 1 at cap 2 runs with 3600 (got '$(AGT)')"
[ "$(jq -r '.timeout_retry | length' "$T/rec-out.json" 2>/dev/null)" = 1 ] && [ "$(jq -r '.fixround_refunds // 0' "$T/rec-out.json" 2>/dev/null)" = 1 ] \
  && ok || bad "R5 a timed-out round 1 at cap 2 takes the retry (mark + refund): $(cat "$T/rec-out.json" 2>/dev/null | head -c 300)"
grep -q 'fix round 1 of 2 did not land' "$LOGF" && bad "R5 round 1 took the rounds-remaining exit, not the retry" || ok
cp "$T/rec-out.json" "$T/rec-in.json"; : > "$T/agent.txt"
FIXHERE red-ci-twice BR_MAX_FIXROUNDS=2
[ "$(AGT)" = 5400 ] && ok || bad "R5 the retry round at cap 2 runs with 5400 (got '$(AGT)'; log: $(tail -3 "$LOGF"))"
[ "$(jq -r '.timeout_retry_ran | length' "$T/rec-out.json" 2>/dev/null)" = 1 ] && ok || bad "R5 the retry round's FIX_RECORD carries the spent budget: $(cat "$T/rec-out.json" 2>/dev/null | head -c 300)"
cp "$T/rec-out.json" "$T/rec-in.json"; : > "$T/agent.txt"
FIXHERE red-ci-twice BR_MAX_FIXROUNDS=2
[ "$(AGT)" = 3600 ] && ok || bad "R5 a later round on the same head, retry spent: 3600 (got '$(AGT)')"

echo "fixround-timeout-budget.bh-10057: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
