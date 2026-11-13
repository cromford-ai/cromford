#!/bin/bash
# tests/fixround-timeout-retry.bh-9404-test.sh — BH-9404 (TK-3699): a fix
# round whose agent call timed out (rc 124) gets ONE more round per PR head
# before the ticket goes to its terminal.
#
# THE INCIDENT (2026-11-09). TK-3699's fix round ran into FIX_AGENT_TIMEOUT.
# br_fix_round recorded the round, saw the cap spent, deleted brfix/<ck> and
# called br_fix_terminal: the PR was closed after one try that never finished.
#
#   U1-U9  brtr_take, the fragment over a real JSON record (the decision table)
#   R1-R6  the REAL bin/blocked-resolver.sh --fix-here (the owning box's half
#          of a hopped round) with a stub agent-call whose rc the suite sets:
#          R1 large park, 124 -> done, mark, refund, brfix kept, 1 event
#          R2 review park, 124 -> done, head un-marked; R2b a second 124 -> terminal
#          R3 rc 1 -> terminal at once; R4 a second 124 on the same head -> terminal
#          R5 BR_FIX_TIMEOUT_RETRIES=0 -> terminal; R6 the REAL br_fix_adopt
#   C1     the driver has one brtr_take call site, in the right place
#   K1-K2  the knob row
# Run from anywhere: tests/fixround-timeout-retry.bh-9404-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "FAIL: jq missing"; exit 1; }
FRAG="$DIR/bin/blocked-resolver.d/bh-9404-timeout-retry.sh"
DRIVER="$DIR/bin/blocked-resolver.sh"
KNOB="$DIR/catalog/lanes.d/blocked-resolver.knobs.d/BR_FIX_TIMEOUT_RETRIES.json"
[ -f "$FRAG" ] || bad "F0 bin/blocked-resolver.d/bh-9404-timeout-retry.sh does not exist"
export GIT_CONFIG_NOSYSTEM=1
lift() { awk -v n="$1" '$0 ~ "^"n"\\(\\) \\{" {f=1} f{print} f&&/^}/{exit}' "$2"; }
H1=1111111111111111111111111111111111111111
H2=2222222222222222222222222222222222222222

# ============================================================================
# U — brtr_take over a real record file, every other verb a stub
# ============================================================================
U="$T/u"; mkdir -p "$U/rec" "$U/repos/tproj"
lift br_json_edit "$DIR/bin/lib/br/record.sh" > "$U/real.sh"
cat > "$U/stubs.sh" <<EOF
H="$U"; ST="$U/st"; REPOS="$U/repos"; LOG="$U/br.log"
STAMP() { printf '2026-11-10T00:00:00Z'; }
say() { printf '%s\n' "\$*" >> "$U/say.log"; }
br_file() { printf '%s' "$U/rec/\$2.json"; }
br_load() { cat "$U/rec/\$2.json" 2>/dev/null || echo '{}'; }
br_save() { printf '%s\n' "\$3" > "$U/rec/\$2.json"; }
br_event() { printf '%s\n' "\$*" >> "$U/events.log"; }
br_wt_drop() { printf '%s\n' "\$*" >> "$U/wtdrop.log"; }
mc_git_auth_clear() { :; }
EOF
UCK=u-1
URESET() { # URESET <record-json>
  rm -f "$U/rec"/*.json "$U/rec-ro"; : > "$U/say.log"; : > "$U/events.log"; : > "$U/wtdrop.log"
  printf '%s\n' "$1" > "$U/rec/$UCK.json"
}
UT() { # UT <reason> <head> <rc> [env...] — brtr_take in a clean shell; prints rc=<n>
  local reason="$1" head="$2" rc="$3"; shift 3
  ( unset BR_FIX_TIMEOUT_RETRIES; for e in "$@"; do export "${e?}"; done
    bash -c '. "$1"; . "$2"; [ -f "$H/rec-ro" ] && br_json_edit() { return 1; }; . "$3"; shift 3; brtr_take "$@"; echo "rc=$?"' _ "$U/stubs.sh" "$U/real.sh" "$FRAG" \
      tproj "$UCK" TK-1 "$reason" "https://github.com/o/tproj/pull/9" "$head" "$rc" 0 2>/dev/null )
}
UJ() { jq -r "$1" "$U/rec/$UCK.json" 2>/dev/null; }
BASE='{"project":"tproj","fixrounds":1,"attempts":[{"action":"fix-round"}]}'

# U1 — the first timeout on a head
URESET "$BASE"
[ "$(UT red-ci-twice "$H1" 124)" = rc=0 ] && ok || bad "U1 rc 124, no mark: the retry is taken (say: $(cat "$U/say.log"))"
[ "$(UJ '.timeout_retry | join(",")')" = "$H1" ] && ok || bad "U1 the mark is the head: $(UJ .timeout_retry)"
[ "$(UJ .fixround_refunds)" = 1 ] && ok || bad "U1 one refund: $(UJ .fixround_refunds)"
[ "$(UJ '.attempts[-1].action')" = fix-round-timeout-retry ] && ok || bad "U1 one attempt row: $(UJ '.attempts[-1]')"
[ "$(UJ '.attempts | length')" = 2 ] && ok || bad "U1 exactly one attempt row is added: $(UJ '.attempts | length')"
grep -q 'one more round next tick, timeout retry 1 of 1' "$U/say.log" && ok || bad "U1 the say line: $(cat "$U/say.log")"
[ "$(grep -c resolver_fix_timeout_retry "$U/events.log")" = 1 ] && ok || bad "U1 one event: $(cat "$U/events.log")"
[ -s "$U/wtdrop.log" ] && ok || bad "U1 the worktree is dropped"

# U2 — review park, H1 spent already, a new head H2 times out
URESET "$(jq -nc --arg a "$H1" --arg b "$H2" '{project:"tproj",fixrounds:1,timeout_retry:[$a],review_fix_heads:[$a,$b],attempts:[]}')"
[ "$(UT review-changes-requested "$H2" 124)" = rc=0 ] && ok || bad "U2 a new head gets its own retry (say: $(cat "$U/say.log"))"
[ "$(UJ '.review_fix_heads | join(",")')" = "$H1" ] && ok || bad "U2 H2 is un-marked, H1 stays: $(UJ .review_fix_heads)"
[ "$(UJ '.timeout_retry | join(",")')" = "$H1,$H2" ] && ok || bad "U2 both heads marked: $(UJ .timeout_retry)"

# U3 — a mark for this head is present: no retry, the record is unchanged
URESET "$(jq -nc --arg a "$H1" '{project:"tproj",fixrounds:2,timeout_retry:[$a],attempts:[]}')"
B=$(cat "$U/rec/$UCK.json")
[ "$(UT red-ci-twice "$H1" 124)" = rc=1 ] && ok || bad "U3 a second timeout on the same head is terminal"
[ "$(cat "$U/rec/$UCK.json")" = "$B" ] && ok || bad "U3 the record is byte-identical"
grep -q 'no timeout retry left' "$U/say.log" && ok || bad "U3 one line says no retry is left: $(cat "$U/say.log")"
[ ! -s "$U/wtdrop.log" ] && ok || bad "U3 the worktree is left to the terminal path"

# U4 / U5 — other exit codes, and strings that only look like 124
for r in 1 0 137 143 1240 " 124" "124 " ""; do
  URESET "$BASE"; B=$(cat "$U/rec/$UCK.json")
  [ "$(UT red-ci-twice "$H1" "$r")" = rc=1 ] && [ "$(cat "$U/rec/$UCK.json")" = "$B" ] && [ ! -s "$U/events.log" ] \
    && ok || bad "U4/U5 rc '$r' is not a timeout: no retry, record unchanged"
done

# U6 — knob 0 turns it off; U7 junk knob -> fallback 1, one line
URESET "$BASE"
[ "$(UT red-ci-twice "$H1" 124 BR_FIX_TIMEOUT_RETRIES=0)" = rc=1 ] && [ "$(UJ '.timeout_retry // [] | length')" = 0 ] \
  && ok || bad "U6 BR_FIX_TIMEOUT_RETRIES=0: a timeout is terminal, as before"
[ ! -s "$U/say.log" ] && ok || bad "U6 the knob at 0 is silent, as before BH-9404 (no 'timed out again' line): $(cat "$U/say.log")"
URESET "$BASE"
[ "$(UT red-ci-twice "$H1" 124 BR_FIX_TIMEOUT_RETRIES=x)" = rc=0 ] && ok || bad "U7 a junk knob uses the fallback 1"
[ "$(grep -c "BR_FIX_TIMEOUT_RETRIES is 'x'" "$U/say.log")" = 1 ] && ok || bad "U7 one line names the fallback: $(cat "$U/say.log")"
URESET "$(jq -nc --arg a "$H1" '{project:"tproj",timeout_retry:[$a],attempts:[]}')"
[ "$(UT red-ci-twice "$H1" 124 BR_FIX_TIMEOUT_RETRIES=2)" = rc=0 ] && [ "$(UJ '.timeout_retry | length')" = 2 ] \
  && ok || bad "U7b BR_FIX_TIMEOUT_RETRIES=2: a second retry on one head"

# U8 — the record write fails: no retry is announced, the terminal runs
URESET "$BASE"; touch "$U/rec-ro"   # br_json_edit answers 1, as it does when jq or the load fails
[ "$(UT red-ci-twice "$H1" 124)" = rc=1 ] && ok || bad "U8 a failed write falls to the terminal"
grep -q 'one more round' "$U/say.log" && bad "U8 no 'one more round' line after a failed write" || ok
grep -q 'the timeout retry was not recorded' "$U/say.log" && ok || bad "U8 one line says the retry was not recorded: $(cat "$U/say.log")"
[ ! -s "$U/events.log" ] && ok || bad "U8 no event after a failed write"

# U9 — an unknown head is key '-', once per record
URESET "$BASE"
[ "$(UT red-ci-twice "" 124)" = rc=0 ] && [ "$(UJ '.timeout_retry | join(",")')" = "-" ] && ok || bad "U9 an empty head is keyed '-': $(UJ .timeout_retry)"
[ "$(UT red-ci-twice "" 124)" = rc=1 ] && ok || bad "U9 a second timeout with no head is terminal"
URESET "$BASE"
[ "$(UT red-ci-twice "$(printf '%s' "$H1" | tr 1 A)" 124)" = rc=0 ] && [ "$(UJ '.timeout_retry[0]')" = "$(printf '%s' "$H1" | tr 1 a)" ] \
  && ok || bad "U9 an upper-case head is lower-cased: $(UJ .timeout_retry)"

# ============================================================================
# R — the REAL driver, --fix-here (the owning box's half of a hopped round)
# ============================================================================
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
[ -f "$FRAG" ] && { scratch_install_closure bin/blocked-resolver.d/bh-9404-timeout-retry.sh "$H" >/dev/null || { echo "FAIL: closure of the fragment"; exit 1; }; }
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
mrs_fixture "$H" tproj
fx_br_ladder_git "$DIR" "$T" || exit 1
git -C "$T/repos/tproj" fetch -q origin
# The "agent": counts its calls and exits with the rc the suite wrote.
cat > "$H/bin/agent-call.sh" <<AGENT
#!/bin/bash
printf '%s\n' "\$*" >> "$T/agent.txt"
exit "\$(cat "$T/agent-rc" 2>/dev/null || echo 0)"
AGENT
chmod +x "$H/bin/agent-call.sh"
PR="https://github.com/o/tproj/pull/91"
LOGF="$H/logs/blocked-resolver.log"
CK=tr-1
FIXHERE() { # FIXHERE <reason> [env...] — one hopped round; stdout in $T/fh.out
  local reason="$1"; shift
  ( for e in "$@"; do export "${e?}"; done
    HARNESS="$H" FLEET_CONF="$H/fleet.conf" REPOS_ROOT="$T/repos" BOX_NAME=box-tproj \
      bash "$H/bin/blocked-resolver.sh" --fix-here tproj "$CK" "$reason" "$PR" - - < "$T/rec-in.json" ) > "$T/fh.out" 2>>"$T/run.log"
  sed -n 's/^FIX_RECORD //p' "$T/fh.out" | base64 -d > "$T/rec-out.json" 2>/dev/null
}
RESULT() { sed -n 's/^FIX_RESULT //p' "$T/fh.out" | head -1; }
OUTJ() { jq -r "$1" "$T/rec-out.json" 2>/dev/null; }
RRESET() { # RRESET <branch> <agent-rc>
  scratch_rm "$H/state/blocked-resolver"; scratch_rm "$H/tmp/brfix"
  : > "$LOGF"; : > "$T/agent.txt"; : > "$T/comments.txt"
  rm -f "$T/fh.out" "$T/rec-out.json"
  git -C "$T/repos/tproj" worktree prune >/dev/null 2>&1
  git -C "$T/repos/tproj" for-each-ref --format='%(refname:short)' refs/heads/brfix/ \
    | while read -r b; do git -C "$T/repos/tproj" branch -D "$b" >/dev/null 2>&1; done
  printf '%s\n' "$1" > "$T/prbranch"; osha "$1" | tr -d '\n' > "$T/prhead"; printf 'main\n' > "$T/prbase"
  printf '%s' "$2" > "$T/agent-rc"
  jq -nc --arg k "$CK" '{project:"tproj",rkey:$k,fixrounds:0,rebuilds:0,mechanicals:1,outcome:"",attempts:[]}' > "$T/rec-in.json"
}
BRFIX() { git -C "$T/repos/tproj" rev-parse --verify -q "brfix/$CK" >/dev/null 2>&1; }
NAGENT() { grep -c "^execute " "$T/agent.txt"; }

# R1 — the incident: a large park (cap 1), the agent times out
RRESET ticket/TK-90 124
HD=$(osha ticket/TK-90)
FIXHERE red-ci-twice
[ "$(NAGENT)" = 1 ] && ok || bad "R1 the round reached the agent once (log: $(tail -4 "$LOGF"))"
[ "$(RESULT)" = done ] && ok || bad "R1 a first timeout is not a terminal: FIX_RESULT done (got '$(RESULT)'; log: $(grep -i 'timed out\|did not produce' "$LOGF" | tail -2))"
[ "$(OUTJ '.timeout_retry | join(",")')" = "$HD" ] && ok || bad "R1 the record carries the mark for the head: $(OUTJ .timeout_retry)"
[ "$(OUTJ .fixround_refunds)" = 1 ] && ok || bad "R1 the round is refunded: $(OUTJ .fixround_refunds)"
[ "$(OUTJ .fixrounds)" = 1 ] && ok || bad "R1 the round is still recorded: fixrounds 1 (got $(OUTJ .fixrounds))"
[ "$(OUTJ '.attempts[-1].action')" = fix-round-timeout-retry ] && ok || bad "R1 the last attempt is fix-round-timeout-retry: $(OUTJ '.attempts[-1]')"
BRFIX && ok || bad "R1 brfix/$CK is kept for the next round"
[ "$(grep -c 'EVENT resolver_fix_timeout_retry' "$LOGF")" = 1 ] && ok || bad "R1 exactly one resolver_fix_timeout_retry event: $(grep EVENT "$LOGF")"
[ "$(osha ticket/TK-90)" = "$HD" ] && ok || bad "R1 nothing is pushed"
cp "$T/fh.out" "$T/r1.out"; cp "$T/rec-out.json" "$T/r1.json"

# R4 — R1's record back in, the agent times out again on the same head: terminal
cp "$T/r1.json" "$T/rec-in.json"
FIXHERE red-ci-twice
[ "$(NAGENT)" = 2 ] && ok || bad "R4 the second round ran the agent again (calls: $(NAGENT))"
[ "$(RESULT)" = terminal ] && ok || bad "R4 a second timeout on the same head is the terminal (got '$(RESULT)')"
[ "$(OUTJ '.timeout_retry | length')" = 1 ] && ok || bad "R4 no second mark: $(OUTJ .timeout_retry)"
BRFIX && bad "R4 the terminal drops brfix/$CK, as today" || ok

# R3 — rc 1: the terminal at once, as today
RRESET ticket/TK-90 1
FIXHERE red-ci-twice
[ "$(RESULT)" = terminal ] && ok || bad "R3 rc 1 is the terminal at once (got '$(RESULT)')"
[ "$(OUTJ '.timeout_retry // [] | length')" = 0 ] && [ "$(OUTJ '.fixround_refunds // 0')" = 0 ] \
  && ok || bad "R3 no mark, no refund: $(OUTJ '{timeout_retry, fixround_refunds}')"

# R5 — the knob at 0: a timeout is terminal, as before BH-9404
RRESET ticket/TK-90 124
FIXHERE red-ci-twice BR_FIX_TIMEOUT_RETRIES=0
[ "$(RESULT)" = terminal ] && ok || bad "R5 BR_FIX_TIMEOUT_RETRIES=0 keeps the terminal (got '$(RESULT)')"

# R2 — a review park: its head is marked spent before the agent runs
RRESET ticket/TK-91 124
HR=$(osha ticket/TK-91)
# The lane's review on HR, as GitHub's REST answers the reviews list (the shape
# tests/blocked-resolver.bh-594-test.sh section 3 uses).
REVJSON=$(jq -nc --arg c "$HR" --arg b "$(printf 'Findings.\n\nVERDICT: REQUEST_CHANGES\n\n---\nAutomated harness review (Fable) of abc.')" \
  '[{user:{login:"cromford[bot]", type:"Bot"}, author_association:"MEMBER", commit_id:$c, state:"COMMENTED", body:$b}]')
mv "$T/fakebin/gh" "$T/fakebin/gh-base"
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
case "\$*" in
  *"-i -X GET"*"/pulls/91/reviews"*) printf 'HTTP/2 200\r\nserver: x\r\n\r\n%s' '$REVJSON'; exit 0 ;;
esac
exec "$T/fakebin/gh-base" "\$@"
EOF
chmod +x "$T/fakebin/gh"
FIXHERE review-changes-requested
[ "$(NAGENT)" = 1 ] && ok || bad "R2 the review round reached the agent (log: $(tail -4 "$LOGF"))"
[ "$(RESULT)" = done ] && ok || bad "R2 a first timeout on a review head is not a terminal (got '$(RESULT)')"
[ -s "$T/rec-out.json" ] && [ "$(jq -r --arg h "$HR" '(.review_fix_heads // []) | map(select(. == $h)) | length' "$T/rec-out.json")" = 0 ] \
  && ok || bad "R2 the head is un-marked so the next tick offers it again: $(OUTJ .review_fix_heads)"
[ "$(OUTJ '.timeout_retry | join(",")')" = "$HR" ] && ok || bad "R2 the review head is marked: $(OUTJ .timeout_retry)"
# R2b — the same review head times out again: terminal
cp "$T/rec-out.json" "$T/rec-in.json"
FIXHERE review-changes-requested
[ "$(NAGENT)" = 2 ] && ok || bad "R2b the head was offered again and ran (calls: $(NAGENT); log: $(tail -3 "$LOGF"))"
[ "$(RESULT)" = terminal ] && ok || bad "R2b a second timeout on the same review head is the terminal (got '$(RESULT)')"
mv -f "$T/fakebin/gh-base" "$T/fakebin/gh"

# R6 — R1's box output through the REAL br_fix_adopt on the hub
HB="$T/hub"; mkdir -p "$HB/rec"
cat > "$HB/stubs.sh" <<EOF
H="$HB"; ST="$HB/st"; LOG="$HB/br.log"
say() { printf '%s\n' "\$*" >> "$HB/say.log"; }
br_load() { cat "$HB/rec/\$2.json" 2>/dev/null || echo '{}'; }
br_save() { printf '%s\n' "\$3" > "$HB/rec/\$2.json"; }
fix_round_adopt() { return 0; }
br_fix_terminal() { printf 'terminal\n' >> "$HB/terminal.log"; }
br_fix_terminal_word() { printf terminal; }
br_rebuild_fresh() { printf 'rebuild\n' >> "$HB/terminal.log"; }
EOF
lift br_fix_adopt "$DRIVER" > "$HB/adopt.sh"
[ -s "$HB/adopt.sh" ] && ok || bad "R6 br_fix_adopt could not be lifted"
: > "$HB/terminal.log"; : > "$HB/say.log"
jq -nc --arg k "$CK" '{project:"tproj",rkey:$k,fixrounds:0,attempts:[]}' > "$HB/rec/$CK.json"
R1RES=$(sed -n 's/^FIX_RESULT //p' "$T/r1.out" | head -1)
ROW=$(jq -nc --arg ro "$(cat "$T/r1.json")" --arg r "$R1RES" '{id:7, claimed_by:"box-tproj", result:$r, record_out:$ro}')
bash -c '. "$1"; . "$2"; br_fix_adopt tproj "$3" red-ci-twice "$4" - - "$3" "$5"' _ "$HB/stubs.sh" "$HB/adopt.sh" "$CK" "$PR" "$ROW" >/dev/null 2>&1
[ ! -s "$HB/terminal.log" ] && ok || bad "R6 the hub takes no terminal for a timed-out first round: $(cat "$HB/terminal.log")"
[ "$(jq -r '.timeout_retry | join(",")' "$HB/rec/$CK.json" 2>/dev/null)" = "$HD" ] && ok || bad "R6 the hub record has the mark: $(cat "$HB/rec/$CK.json")"
[ "$(jq -r '.fixround_refunds' "$HB/rec/$CK.json" 2>/dev/null)" = 1 ] && ok || bad "R6 the hub record has the refund"

# ============================================================================
# C — the call site; K — the knob row
# ============================================================================
SITE=$(lift br_fix_round "$DRIVER")
[ "$(printf '%s\n' "$SITE" | grep -c 'brtr_take "')" = 1 ] && [ "$(grep -c 'brtr_take "' "$DRIVER")" = 1 ] \
  && ok || bad "C1 the driver has exactly one brtr_take call line, in br_fix_round"
LC=$(printf '%s\n' "$SITE" | grep -n 'brtr_take "' | cut -d: -f1)
LT=$(printf '%s\n' "$SITE" | grep -n 'fix round did not produce a verified commit' | cut -d: -f1 | head -1)
LR=$(printf '%s\n' "$SITE" | grep -n '"\$((n+1))" -lt "\$cap"' | cut -d: -f1 | awk -v t="${LT:-0}" '$1 < t' | tail -1)
[ -n "$LC" ] && [ -n "$LR" ] && [ -n "$LT" ] && [ "$LR" -lt "$LC" ] && [ "$LC" -lt "$LT" ] \
  && ok || bad "C1 the call is after the rounds-remaining exit ($LR) and before the terminal say ($LT): got ${LC:-none}"
printf '%s\n' "$SITE" | grep 'brtr_take "' | grep -q '&& return 0' && ok || bad "C1 the call site returns 0 after a taken retry"
jq -e '.env == "BR_FIX_TIMEOUT_RETRIES" and .type == "int" and .default == 1 and .min == 0' "$KNOB" >/dev/null 2>&1 \
  && ok || bad "K1 the knob row parses with default 1, min 0"
[ "$(jq -r .read_in "$KNOB" 2>/dev/null)" = bin/blocked-resolver.d/bh-9404-timeout-retry.sh ] && ok || bad "K2 the knob row names the fragment"
grep -q 'BR_FIX_TIMEOUT_RETRIES:-1' "$FRAG" 2>/dev/null && grep -q 'lane.blocked-resolver.BR_FIX_TIMEOUT_RETRIES' "$FRAG" \
  && ok || bad "K2 the fragment reads the knob with the documented fallback 1 and names the row"

echo "fixround-timeout-retry.bh-9404: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
