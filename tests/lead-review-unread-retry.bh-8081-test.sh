#!/bin/bash
# tests/lead-review-unread-retry.bh-8081-test.sh — BH-8081: an unreadable lead
# verdict must not spend the head's only paid call, and a head that stays
# guard-blocked with no verdict raises ONE alert keyed by the LR key.
#   U1-U8  lu_extra_fp (bin/lib/lead-unread.sh), the lib alone, lr_guard_spent
#          stubbed from a fp table: one extra paid call on ~unread (~unbody<D>
#          on a changed body) only when the ~noverdict (~nvbody<D>) retry key is
#          paid, the extra key is free and LEAD_REVIEW_UNREAD_RETRY is on.
#   A1-A5  lu_guard_blocked: the <key>.gblock count and when it alerts.
#   E1-E5  bin/lead-review.sh tick WHOLE against the scratch harness
#          (tests/lib/lead-worklist-fixture.bh-4956.sh), with an agent-call stub
#          that keeps a per-fp paid ledger (a paid lead-head fp = rc 74, the real
#          guard's refusal) and a call-guard peek that reads the same ledger.
#          E1 is the ticket's test: an unreadable round, a reset, one more paid
#          call on ~unread, a second unreadable answer, one lane-alert.
# Every case seeds its own PR number and fresh fixture state. 0 vendor calls:
# the stub is the only bin/agent-call.sh in the scratch harness.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lead-review-unread-retry.bh-8081-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/lead-worklist-fixture.bh-4956.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "FAIL: flock missing"; exit 1; }
SRC=$(cd "$(dirname "$0")/.." && pwd)

# ── U1-U8: the decision, the lib alone ──
U="$T/u"; mkdir -p "$U/h/state" "$U/h/bin"
(
  H="$U/h"; LOG="$U/log"
  log() { echo "$*" >> "$LOG"; }
  . "$SRC/bin/lib/review-bought.sh" || exit 9
  . "$SRC/bin/lib/lead-reviews.sh" || exit 9
  . "$SRC/bin/lib/lead-unread.sh" || exit 9
  # lr_guard_spent stub: a fp listed in $U/spent is paid 1/1; anything else rc 1.
  lr_guard_spent() { grep -qxF "$2" "$U/spent" 2>/dev/null || return 1; printf '1/1'; }
  R=example-org/demo-os; S=0123456789abcdef0123456789abcdef01234567
  BFP=sha256:00000000000a1b2c; BD=$((16#00000000000a))
  P="lead:$R#7@$S"
  set_spent() { printf '%s\n' "$@" > "$U/spent"; }
  dec() { unset LU_FP LU_WHY; LEAD_REVIEW_UNREAD_RETRY="${KNOB-}" lu_extra_fp demo-os "$R" 7 "$S" "$1" "$BFP"; echo "rc=$? fp=${LU_FP:-} why=${LU_WHY:-}"; }
  KNOB=""
  set_spent "$P" "$P~noverdict";                     echo "U1 $(dec 0)"
  set_spent "$P~body$BD" "$P~nvbody$BD";               echo "U2 $(dec 1)"
  set_spent "$P";                                    echo "U3 $(dec 0)"
  set_spent "$P" "$P~noverdict" "$P~unread";         echo "U4 $(dec 0)"
  KNOB=0; set_spent "$P" "$P~noverdict";             echo "U5 $(dec 0)"; KNOB=""
  # U6: the evidence peek cannot be read (a worker 500 is lr_guard_spent rc 1)
  lr_guard_spent() { case "$2" in *~noverdict) return 1 ;; esac; grep -qxF "$2" "$U/spent" 2>/dev/null || return 1; printf '1/1'; }
  set_spent "$P" "$P~noverdict";                     echo "U6 $(dec 0)"
  lr_guard_spent() { grep -qxF "$2" "$U/spent" 2>/dev/null || return 1; printf '1/1'; }
  set_spent "$P~body$BD" "$P~noverdict";              echo "U7 $(dec 1)"
  : > "$LOG"; KNOB=yes; set_spent "$P" "$P~noverdict"; echo "U8 $(dec 0)"; KNOB=""
  echo "U8log $(grep -c 'LEAD_REVIEW_UNREAD_RETRY' "$LOG")"
) > "$U/out" 2>&1
UO="$U/out"; S0=0123456789abcdef0123456789abcdef01234567; BD0=$((16#00000000000a))
UP="lead:example-org/demo-os#7@$S0"
grep -qxF "U1 rc=0 fp=$UP~unread why=" "$UO" && ok || bad "U1 spent ~noverdict: $(grep '^U1' "$UO") $(head -3 "$UO")"
grep -qxF "U2 rc=0 fp=$UP~unbody$BD0 why=" "$UO" && ok || bad "U2 changed body: $(grep '^U2' "$UO")"
grep -qxF "U3 rc=1 fp= why=no-unread-evidence" "$UO" && ok || bad "U3 no evidence: $(grep '^U3' "$UO")"
grep -qxF "U4 rc=1 fp= why=extra-spent" "$UO" && ok || bad "U4 extra spent: $(grep '^U4' "$UO")"
grep -qxF "U5 rc=1 fp= why=off" "$UO" && ok || bad "U5 knob 0: $(grep '^U5' "$UO")"
grep -qxF "U6 rc=1 fp= why=no-unread-evidence" "$UO" && ok || bad "U6 unreadable peek must not spend: $(grep '^U6' "$UO")"
grep -qxF "U7 rc=1 fp= why=no-unread-evidence" "$UO" && ok || bad "U7 other body's evidence: $(grep '^U7' "$UO")"
grep -qxF "U8 rc=0 fp=$UP~unread why=" "$UO" && ok || bad "U8 bad knob = default 1: $(grep '^U8' "$UO")"
grep -qxF "U8log 1" "$UO" && ok || bad "U8 want one knob log line: $(grep '^U8log' "$UO")"

# ── A1-A5: lu_guard_blocked counts and alerts ──
A="$T/a"; mkdir -p "$A/h/bin" "$A/h/state/lead-reviews"
cat > "$A/h/bin/lane-alert.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$A/alerts"
EOF
chmod +x "$A/h/bin/lane-alert.sh"
ablk() { # ablk <key> <why> [ticks knob] — one blocked tick; prints the marker count
  ( H="$A/h"; log() { echo "$*" >> "$A/log"; }
    . "$SRC/bin/lib/lead-unread.sh" || exit 9
    LU_WHY="$2" LEAD_REVIEW_GUARD_ALERT_TICKS="${3-}" lu_guard_blocked demo-os example-org/demo-os 9 "$S0" "$1" "lead:example-org/demo-os#9@$S0" 1/1 )
  head -n 1 "$A/h/state/lead-reviews/$1.gblock" 2>/dev/null
}
acnt() { local n; n=$(grep -c . "$A/alerts" 2>/dev/null); echo "${n:-0}"; }
rm -f "$A/alerts"; [ "$(ablk lr-9-a no-unread-evidence)" = 1 ] && [ "$(acnt)" = 0 ] && ok || bad "A1 count 1 must not alert: alerts=$(acnt)"
[ "$(ablk lr-9-a no-unread-evidence)" = 2 ] && [ "$(acnt)" = 1 ] && ok || bad "A2 count 2 must alert once: alerts=$(acnt)"
grep -q -- "--severity warn --id lead-noverdict-example-org_demo-os-9-${S0:0:12} lead-review .*guard-blocked 2 ticks.*call-guard-reset demo-os lead-head \"lead:example-org/demo-os#9@$S0\"" "$A/alerts" && ok \
  || bad "A2 alert line: $(cat "$A/alerts")"
[ "$(ablk lr-9-a no-unread-evidence)" = 3 ] && ok || bad "A2b third tick count"
[ "$(grep -o -- '--id [^ ]*' "$A/alerts" | sort -u | wc -l)" = 1 ] && ok || bad "A2b a third tick named another alert id: $(cat "$A/alerts")"
rm -f "$A/alerts"; [ "$(ablk lr-9-b extra-spent)" = 1 ] && [ "$(acnt)" = 1 ] && grep -q 'extra paid call already spent' "$A/alerts" && ok \
  || bad "A3 extra-spent alerts on tick 1: $(cat "$A/alerts" 2>/dev/null)"
rm -f "$A/alerts"; ablk lr-9-c no-unread-evidence 0 >/dev/null; ablk lr-9-c no-unread-evidence 0 >/dev/null; ablk lr-9-c extra-spent 0 >/dev/null
[ "$(acnt)" = 0 ] && ok || bad "A4 ticks knob 0 must never alert: $(cat "$A/alerts")"
rm -f "$A/alerts"; echo 1 > "$A/h/state/lead-reviews/lr-9-d.gblock"; touch -d '-2 days' "$A/h/state/lead-reviews/lr-9-d.gblock"
[ "$(ablk lr-9-d no-unread-evidence)" = 1 ] && [ "$(acnt)" = 0 ] && ok || bad "A5 a marker older than the window must restart at 1"

# ── E1-E5: the whole tick ──
lwf_setup
export LEAD_REVIEW_MAX_PER_PR_DAY=20
# The agent-call stub: a per-fp paid ledger. A lead-head fp already paid is the
# real guard's refusal (rc 74, nothing billed, no answer). Else the fp is paid,
# and the answer has no VERDICT line while $FX/unreadable exists.
cat > "$H/bin/agent-call.sh" <<EOF
#!/bin/bash
pr="\${AGENT_CALL_PR##*/}"; fp="\${AGENT_CALL_FP:-}"; led="$FX/paid.\$(printf '%s' "\$fp" | tr -c 'A-Za-z0-9' '_')"
if [ "\${AGENT_CALL_GUARD_STAGE:-}" = lead-head ] && [ -n "\$fp" ] && [ -e "\$led" ]; then
  printf '%s\n' "\$fp" >> "$T/log/agent-refused"; exit 74
fi
[ -n "\$fp" ] && : > "\$led"
printf '%s\n' "\$pr" >> "$T/log/agent-prs"; printf '%s %s\n' "\${AGENT_CALL_GUARD_STAGE:-}" "\$fp" >> "$T/log/agent-fps"
if [ -e "$FX/unreadable" ]; then printf 'I looked at it.\n' > "\$5"
else printf 'Findings\n- none\n\nVERDICT: MERGE\n' > "\$5"; fi
exit 0
EOF
chmod +x "$H/bin/agent-call.sh"
mv "$T/fakebin/curl" "$T/fakebin/curl.fx"
cat > "$T/fakebin/curl" <<EOF
#!/bin/bash
url=""; for a in "\$@"; do case "\$a" in http*) url="\$a" ;; esac; done
p="\${url#https://jobs.test}"
case "\$p" in
  /api/call-guard\?*)
    ( flock 9; printf 'GET %s \n' "\$p" >> "$T/log/worker" ) 9>"$T/worker.lock"
    f=\$(printf '%s' "\$p" | sed -n 's/.*[?&]fp=\([^&]*\).*/\1/p'); f=\$(printf '%b' "\${f//%/\\\\x}")
    if [ -e "$FX/paid.\$(printf '%s' "\$f" | tr -c 'A-Za-z0-9' '_')" ]; then
      jq -nc --arg f "\$f" '{rows:[{project:"demo-os", stage:"lead-head", fp:\$f, paid:1, refused:0}], hours:24}'
    else printf '{"rows":[],"hours":24}'; fi
    printf '\n200'; exit 0 ;;
esac
exec "$T/fakebin/curl.fx" "\$@"
EOF
chmod +x "$T/fakebin/curl"
S12=${SHA:0:12}
FPB() { printf 'lead:example-org/demo-os#%s@%s' "$1" "$SHA"; }
paid() { : > "$FX/paid.$(printf '%s' "$1" | tr -c 'A-Za-z0-9' '_')"; }
calls() { lwf_cnt . "$T/log/agent-fps"; }
# reset <pr> <n> — lead-review-land's requeue: reset_count n, reset_at later
#   than every file this head wrote
reset_req() {
  find "$H/state/lead-reviews" -maxdepth 1 -type f \( -name '*.empty' -o -name '*.md' \) -exec touch -d '-1 hour' {} + 2>/dev/null
  jq -c --arg t "$(date -u '+%Y-%m-%d %H:%M:%S')" --argjson n "$2" 'map(.reset_count = $n | .reset_at = $t)' "$FX/rows.json" > "$FX/rows.n" && mv -f "$FX/rows.n" "$FX/rows.json"
}
newtick() { : > "$T/log/agent-fps"; : > "$T/log/agent-prs"; rm -f "$T/log/agent-refused" "$L"; : > "$T/log/worker"; }
alerts() { lwf_cnt . "$T/log/lane-alert"; }
alert_ids() { grep -o -- '--id [^ ]*' "$T/log/lane-alert" 2>/dev/null | sort -u | wc -l | tr -d ' '; }
emptyf() { printf '%s/state/lead-reviews/lr-%s-%s.empty' "$H" "$1" "$S12"; }

# ── E1: unreadable, reset, one more paid call on ~unread, unreadable, one alert ──
lwf_reset; N=104; K="lr-$N-$S12"; FP=$(FPB $N)
lwf_rows requested $N; : > "$FX/unreadable"; newtick
lwf_tick
[ "$(calls)" = 2 ] && grep -qxF "lead-head $FP" "$T/log/agent-fps" && grep -qxF "lead-head $FP~noverdict" "$T/log/agent-fps" && ok \
  || bad "E1 tick 1 want 2 calls on the plain and ~noverdict keys: $(cat "$T/log/agent-fps")"
grep -q "^POST /api/lead-reviews/r-$N/result .*\"outcome\":\"failed\".*\"detail\":\"empty\"" "$T/log/worker" && ok || bad "E1 tick 1 not failed empty: $(grep "r-$N" "$T/log/worker")"
[ "$(alerts)" = 0 ] && ok || bad "E1 tick 1 alerted: $(cat "$T/log/lane-alert")"
grep -q 'one more paid call' "$L" && bad "E1 tick 1 logged an extra call" || ok
reset_req $N 1; newtick
lwf_tick
[ "$(calls)" = 1 ] && grep -qxF "lead-head $FP~unread" "$T/log/agent-fps" && ok \
  || bad "E1 tick 2 want exactly 1 call on $FP~unread: calls=$(calls) $(cat "$T/log/agent-fps") refused=$(cat "$T/log/agent-refused" 2>/dev/null) log=$(grep "$K" "$L")"
grep -qF "$K: lead-head paid 1/1 on $FP with no readable verdict; one more paid call on $FP~unread (BH-8081)" "$L" && ok || bad "E1 tick 2 no extra-call line: $(grep "$K" "$L")"
grep -q "noverdict" "$T/log/agent-fps" && bad "E1 tick 2 retried on ~noverdict" || ok
[ -f "$(emptyf $N)" ] && ok || bad "E1 tick 2 no .empty marker"
grep -q "^POST /api/lead-reviews/r-$N/result .*\"detail\":\"empty\"" "$T/log/worker" && ok || bad "E1 tick 2 not failed empty"
[ "$(alerts)" = 1 ] && grep -q -- "--severity warn --id lead-noverdict-example-org_demo-os-$N-$S12 lead-review .*second unreadable answer" "$T/log/lane-alert" && ok \
  || bad "E1 tick 2 want 1 lane-alert: $(cat "$T/log/lane-alert" 2>/dev/null)"
reset_req $N 2; newtick
lwf_tick
[ "$(calls)" = 0 ] && ok || bad "E1 tick 3 made $(calls) calls (want 0)"
grep -q "$K: claim released" "$L" && ok || bad "E1 tick 3 claim not released: $(grep "$K" "$L")"
[ "$(alert_ids)" = 1 ] && ok || bad "E1 tick 3 alert ids=$(alert_ids) (want 1)"

# ── E2: the extra round is readable ──
lwf_reset; N=105; K="lr-$N-$S12"; FP=$(FPB $N)
lwf_rows requested $N; : > "$FX/unreadable"; newtick
lwf_tick
reset_req $N 1; rm -f "$FX/unreadable"; newtick
lwf_tick
[ "$(calls)" = 1 ] && grep -qxF "lead-head $FP~unread" "$T/log/agent-fps" && ok || bad "E2 want 1 call on ~unread: $(cat "$T/log/agent-fps")"
grep -q "done $K: VERDICT MERGE" "$L" && ok || bad "E2 no done line: $(grep "$K" "$L")"
[ "$(alerts)" = 0 ] && ok || bad "E2 a readable extra round alerted"

# ── E3: paid once, no unreadable evidence: alert on the 2nd blocked tick, once ──
lwf_reset; N=106; K="lr-$N-$S12"; FP=$(FPB $N)
lwf_rows requested $N; paid "$FP"; newtick
lwf_tick
[ "$(calls)" = 0 ] && grep -q "$K: lead-head call-guard paid 1/1 on $FP; no rules pack, no host suite, no agent call" "$L" && ok || bad "E3 tick 1: $(grep "$K" "$L")"
[ "$(alerts)" = 0 ] && ok || bad "E3 tick 1 alerted"
[ "$(cat "$H/state/lead-reviews/$K.gblock" 2>/dev/null)" = 1 ] && ok || bad "E3 tick 1 .gblock=$(cat "$H/state/lead-reviews/$K.gblock" 2>/dev/null)"
newtick; lwf_tick
[ "$(alerts)" = 1 ] && grep -q -- "--id lead-noverdict-example-org_demo-os-$N-$S12 .*guard-blocked 2 ticks" "$T/log/lane-alert" && ok || bad "E3 tick 2 want 1 alert: $(cat "$T/log/lane-alert" 2>/dev/null)"
grep -q "$K: claim released" "$L" && ok || bad "E3 tick 2 claim not released"
newtick; lwf_tick
[ "$(alert_ids)" = 1 ] && [ "$(cat "$H/state/lead-reviews/$K.gblock")" = 3 ] && ok || bad "E3 tick 3 ids=$(alert_ids) count=$(cat "$H/state/lead-reviews/$K.gblock")"
[ "$(calls)" = 0 ] && ok || bad "E3 tick 3 made a call"

# ── E4: the extra key is already spent: 0 calls, alert on the first blocked tick ──
lwf_reset; N=107; K="lr-$N-$S12"; FP=$(FPB $N)
lwf_rows requested $N; paid "$FP"; paid "$FP~noverdict"; paid "$FP~unread"; newtick
lwf_tick
[ "$(calls)" = 0 ] && [ ! -e "$T/log/agent-refused" ] && ok || bad "E4 calls=$(calls) refused=$(cat "$T/log/agent-refused" 2>/dev/null)"
[ "$(alerts)" = 1 ] && grep -q 'extra paid call already spent' "$T/log/lane-alert" && ok || bad "E4 want 1 alert: $(cat "$T/log/lane-alert" 2>/dev/null)"
grep -q "$K: claim released" "$L" && ok || bad "E4 claim not released"

# ── E5: LEAD_REVIEW_UNREAD_RETRY=0 is today's behaviour ──
lwf_reset; N=108; K="lr-$N-$S12"; FP=$(FPB $N)
lwf_rows requested $N; : > "$FX/unreadable"; newtick
LEAD_REVIEW_UNREAD_RETRY=0 lwf_tick
reset_req $N 1; newtick
LEAD_REVIEW_UNREAD_RETRY=0 lwf_tick
[ "$(calls)" = 0 ] && ok || bad "E5 knob 0 made $(calls) calls"
grep -q "$K: lead-head call-guard paid 1/1 on $FP; no rules pack, no host suite, no agent call" "$L" && ok || bad "E5 no BH-7792 line: $(grep "$K" "$L")"
grep -q 'one more paid call' "$L" && bad "E5 knob 0 logged an extra call" || ok

# Budget: the only agent-call in the scratch harness is the stub.
grep -q 'paid ledger\|agent-refused' "$H/bin/agent-call.sh" && ok || bad "budget: the scratch agent-call is not the stub"

echo "lead-review-unread-retry.bh-8081: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
