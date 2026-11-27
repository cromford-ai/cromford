#!/bin/bash
# tests/fixround-nothing-new-park.bh-10248-test.sh — a fix round that
# records nothing new is not re-offered for ever on the same head.
#
# THE INCIDENT (2026-11-26). Four cromford PRs with a lead BLOCK (#9510,
# #9643, #9974, #10045) took 10 to 19 fix rounds each. Every round answered
# `done` with the record it was given (n_in == n_out), so br_fix_adopt said
# "recorded nothing new — re-offered next tick" and the next tick queued the
# same round again, ~5 minutes of a Fly machine each time. The box half stopped
# at the (PR, head) dedupe: the head was already in review_fix_heads.
#
#   K*  brnn_max: the knob, its fallback, its clamp, 0 = off
#   A*  the REAL br_fix_adopt (lifted from the driver): a nothing-new adopt
#       counts per head; the count resets on another head or when the record
#       grew; at BR_FIX_NOTHING_NEW_MAX the park is parked, ONE alert + event
#   G*  brnn_gate on the hub: below the cap it queues; at the cap and the live
#       head unchanged it does not; a moved head lifts the park; an unreadable
#       head stays parked this tick; knob 0 never parks
#   R*  the REAL br_fix_remote: a parked park queues no fix_round_jobs row
#   W*  the wiring: one call site each in the driver, the knob row
# Run from anywhere (exit 0 = all pass).
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "FAIL: jq missing"; exit 1; }
FRAG="$DIR/bin/blocked-resolver.d/bh-10248-nothing-new-park.sh"
DRIVER="$DIR/bin/blocked-resolver.sh"
KNOB="$DIR/catalog/lanes.d/blocked-resolver.knobs.d/BR_FIX_NOTHING_NEW_MAX.json"
[ -f "$FRAG" ] || { bad "F0 $FRAG does not exist"; echo "fixround-nothing-new-park: $PASS passed, $FAIL failed"; exit 1; }

HB="$T/hub"; mkdir -p "$HB/rec" "$HB/bin"
CK=tproj-TP-7
PR=https://github.com/o/tproj/pull/91
HA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
HBB=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/alerts.log"\n' "$HB" > "$HB/bin/lane-alert.sh"
printf '#!/bin/bash\necho box-small\n' > "$HB/bin/box-for.sh"
chmod +x "$HB/bin/lane-alert.sh" "$HB/bin/box-for.sh"
lift() { awk -v n="$1" '$0 ~ "^"n"\\(\\) \\{" {f=1} f{print} f&&/^}/{exit}' "$2"; }
lift br_fix_adopt "$DRIVER" > "$HB/adopt.sh"
lift br_fix_remote "$DRIVER" > "$HB/remote.sh"
[ -s "$HB/adopt.sh" ] && [ -s "$HB/remote.sh" ] && ok || bad "F1 br_fix_adopt / br_fix_remote could not be lifted"
cat > "$HB/stubs.sh" <<EOF
H="$HB"; ST="$HB/st"; REPOS="$HB/repos"; LOG="$HB/br.log"; OBSERVE=0
STAMP() { printf '2026-11-26T00:00:00Z'; }
say() { printf '%s\n' "\$*" >> "$HB/say.log"; }
br_load() { cat "$HB/rec/\$2.json" 2>/dev/null || echo '{}'; }
br_save() { printf '%s\n' "\$3" > "$HB/rec/\$2.json"; }
br_json_edit() { [ -f "$HB/rec-ro" ] && return 1; local p="\$1" k="\$2" f="\$3" c; shift 3; c=\$(br_load "\$p" "\$k" | jq -c "\$@" "\$f") && [ -n "\$c" ] && br_save "\$p" "\$k" "\$c"; }
br_event() { printf '%s\n' "\$*" >> "$HB/events.log"; }
fix_round_adopt() { return 0; }
mc_slug_of_url() { printf 'o/tproj'; }
mc_num_of_url() { printf '%s' "\${1##*/}"; }
mc_pr_live_head() { printf '%s\n' "\$*" >> "$HB/live-reads.log"; [ -f "$HB/live-fail" ] && return 1; cat "$HB/live"; }
br_hop_labels() { :; }
is_hub_box() { return 1; }
br_hop_record() { printf '{}'; }
fix_round_enqueue() { printf '%s\n' "\$*" >> "$HB/enqueue.log"; printf '{"id":5}'; }
EOF
RESET() { # RESET [head] — a hub record whose last round answered on <head>
  rm -f "$HB"/rec/*.json "$HB/rec-ro" "$HB/live-fail"
  : > "$HB/say.log"; : > "$HB/events.log"; : > "$HB/alerts.log"; : > "$HB/enqueue.log"; : > "$HB/live-reads.log"
  jq -nc --arg h "${1:-$HA}" '{project:"tproj",fixrounds:1,attempts:[{action:"fix-round"},{action:"fix-round-agent-done"}],
    review_fix_heads:[$h],sup_pr:"https://github.com/o/tproj/pull/91",sup_head:$h}' > "$HB/rec/$CK.json"
  printf '%s' "${1:-$HA}" > "$HB/live"
}
HUB() { # HUB <fn> <args...> — stubs + fragment + lifted driver functions, a clean shell
  ( unset BR_FIX_NOTHING_NEW_MAX BR_FIX_HERE LANE_RUN_ID
    [ -n "${HUBENV:-}" ] && export "${HUBENV?}"
    bash -c '. "$1"; . "$2"; . "$3"; . "$4"; shift 4; "$@"' _ "$HB/stubs.sh" "$FRAG" "$HB/adopt.sh" "$HB/remote.sh" "$@" )
}
REC() { jq -r "$1" "$HB/rec/$CK.json" 2>/dev/null; }
ADOPT() { # ADOPT [record_out] — the box answered done with this record (default: the hub's own)
  local ro="${1:-$(cat "$HB/rec/$CK.json")}" row
  row=$(jq -nc --arg ro "$ro" '{id:7, claimed_by:"box-small", result:"done", record_out:$ro}')
  HUB br_fix_adopt tproj "$CK" review-changes-requested "$PR" - - "$CK" "$row" >/dev/null 2>&1
}
GATE() { local rc=0; HUB brnn_gate tproj "$CK" "$CK" review-changes-requested "$PR" >/dev/null 2>&1 || rc=$?; printf '%s' "$rc"; }

# K — the knob
K() { HUBENV="${1:-}" HUB brnn_max; }
[ "$(K)" = 3 ] && ok || bad "K1 the fallback is 3: $(K)"
[ "$(K BR_FIX_NOTHING_NEW_MAX=5)" = 5 ] && ok || bad "K2 5 is 5: $(K BR_FIX_NOTHING_NEW_MAX=5)"
[ "$(K BR_FIX_NOTHING_NEW_MAX=x)" = 3 ] && ok || bad "K3 a non-number is the fallback: $(K BR_FIX_NOTHING_NEW_MAX=x)"
[ "$(K BR_FIX_NOTHING_NEW_MAX=99)" = 20 ] && ok || bad "K4 over 20 is 20: $(K BR_FIX_NOTHING_NEW_MAX=99)"
[ "$(K BR_FIX_NOTHING_NEW_MAX=0)" = 0 ] && ok || bad "K5 0 is off: $(K BR_FIX_NOTHING_NEW_MAX=0)"

# A — the count, through the REAL br_fix_adopt
RESET; ADOPT
[ "$(REC '.nothing_new.n')" = 1 ] && [ "$(REC '.nothing_new.head')" = "$HA" ] && ok || bad "A1 one nothing-new adopt counts 1 on the head: $(REC '.nothing_new')"
grep -q 'recorded nothing new' "$HB/say.log" && ok || bad "A1 the driver's line is still said"
[ ! -s "$HB/alerts.log" ] && ok || bad "A1 no alert below the cap: $(cat "$HB/alerts.log")"
ADOPT
[ "$(REC '.nothing_new.n')" = 2 ] && ok || bad "A2 a second adopt on the same head counts 2: $(REC '.nothing_new')"
[ "$(REC '.attempts | length')" = 2 ] && ok || bad "A2 the count writes no attempt row: $(REC '.attempts|length')"
ADOPT
[ "$(REC '.nothing_new.n')" = 3 ] && ok || bad "A3 a third counts 3: $(REC '.nothing_new')"
[ "$(grep -c . "$HB/alerts.log")" = 1 ] && grep -q "fix-round-nothing-new-tproj-$CK-${HA:0:8}" "$HB/alerts.log" && ok || bad "A3 one alert at the cap, keyed on the head: $(cat "$HB/alerts.log")"
[ "$(grep -c resolver_fix_nothing_new_park "$HB/events.log")" = 1 ] && ok || bad "A3 one park event: $(cat "$HB/events.log")"
grep -q 'PARKED' "$HB/say.log" && ok || bad "A3 the park is said: $(tail -2 "$HB/say.log")"
# A4: the box read a new live head (sup_head in record_out): the count restarts there
RESET; ADOPT; ADOPT
ADOPT "$(REC ".sup_head = \"$HBB\" | tostring" | jq -c .)"
[ "$(REC '.nothing_new.head')" = "$HBB" ] && [ "$(REC '.nothing_new.n')" = 1 ] && ok || bad "A4 another head restarts the count at 1: $(REC '.nothing_new')"
# A5: a round that recorded an attempt resets the streak
RESET; ADOPT; ADOPT
ADOPT "$(REC '.attempts += [{action:"fix-round"}] | tostring' | jq -c .)"
grep -q 'fix round ran on' "$HB/say.log" && ok || bad "A5 the grown record is adopted as a round that ran"
ADOPT
[ "$(REC '.nothing_new.n')" = 1 ] && ok || bad "A5 after a round that recorded something the count restarts at 1: $(REC '.nothing_new')"
# A6: knob 0 counts nothing
RESET; HUBENV=BR_FIX_NOTHING_NEW_MAX=0 ADOPT; HUBENV=BR_FIX_NOTHING_NEW_MAX=0 ADOPT; HUBENV=BR_FIX_NOTHING_NEW_MAX=0 ADOPT
[ "$(REC '.nothing_new // "none"')" = none ] && [ ! -s "$HB/alerts.log" ] && ok || bad "A6 knob 0 writes nothing: $(REC '.nothing_new')"
# A7: a record that will not write: one line, no alert, no crash
RESET; touch "$HB/rec-ro"; ADOPT; ADOPT; ADOPT
[ ! -s "$HB/alerts.log" ] && grep -q 'could not record' "$HB/say.log" && ok || bad "A7 an unwritable record parks nothing and says so: $(tail -2 "$HB/say.log")"

# G — the gate
RESET; ADOPT; ADOPT
[ "$(GATE)" = 1 ] && ok || bad "G1 below the cap the round is queued (rc 1)"
[ ! -s "$HB/live-reads.log" ] && ok || bad "G1 below the cap no GitHub read: $(cat "$HB/live-reads.log")"
ADOPT
[ "$(GATE)" = 0 ] && ok || bad "G2 at the cap, same live head: parked (rc 0)"
[ "$(grep -c . "$HB/live-reads.log")" = 1 ] && ok || bad "G2 one live-head read: $(cat "$HB/live-reads.log")"
touch "$HB/live-fail"
[ "$(GATE)" = 0 ] && [ "$(REC '.nothing_new.n')" = 3 ] && ok || bad "G3 an unreadable live head stays parked, record kept: $(REC '.nothing_new')"
rm -f "$HB/live-fail"; printf '%s' "$HBB" > "$HB/live"
[ "$(GATE)" = 1 ] && [ "$(REC '.nothing_new // "none"')" = none ] && ok || bad "G4 a moved head lifts the park and clears the count: $(REC '.nothing_new')"
RESET; ADOPT; ADOPT; ADOPT
[ "$(HUBENV=BR_FIX_NOTHING_NEW_MAX=0 GATE)" = 1 ] && ok || bad "G5 knob 0 never parks"
[ "$(HUBENV=BR_FIX_NOTHING_NEW_MAX=5 GATE)" = 1 ] && ok || bad "G6 a raised knob lets the park run again"

# R — the REAL br_fix_remote
RESET; ADOPT; ADOPT; ADOPT; : > "$HB/enqueue.log"
HUB br_fix_remote tproj "$CK" review-changes-requested "$PR" - - "$CK" 0 >/dev/null 2>&1
[ ! -s "$HB/enqueue.log" ] && ok || bad "R1 a parked park queues no fix round: $(cat "$HB/enqueue.log")"
RESET; ADOPT
HUB br_fix_remote tproj "$CK" review-changes-requested "$PR" - - "$CK" 0 >/dev/null 2>&1
[ "$(grep -c . "$HB/enqueue.log")" = 1 ] && ok || bad "R2 below the cap the round is queued: $(cat "$HB/enqueue.log"); say: $(tail -3 "$HB/say.log")"

# W — the wiring
[ "$(lift br_fix_remote "$DRIVER" | grep -c 'brnn_gate ')" = 1 ] && ok || bad "W1 one brnn_gate call in br_fix_remote"
[ "$(lift br_fix_adopt "$DRIVER" | grep -c 'brnn_note ')" = 1 ] && ok || bad "W2 one brnn_note call in br_fix_adopt"
[ "$(grep -c 'brnn_' "$DRIVER")" = 2 ] && ok || bad "W3 the driver names brnn_ exactly twice: $(grep -c 'brnn_' "$DRIVER")"
jq -e '.env == "BR_FIX_NOTHING_NEW_MAX" and .default == 3 and .min == 0 and .max == 20
  and .read_in == "bin/blocked-resolver.d/bh-10248-nothing-new-park.sh"' "$KNOB" >/dev/null 2>&1 && ok || bad "W4 the knob row $KNOB"

echo "fixround-nothing-new-park: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
