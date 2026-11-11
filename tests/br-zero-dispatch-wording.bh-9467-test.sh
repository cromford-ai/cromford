#!/bin/bash
# tests/br-zero-dispatch-wording.bh-9467-test.sh — BH-9467 T6: the
# ZERO_DISPATCH line of bin/blocked-resolver.sh says how many hand-offs got NO
# ack this tick and how many WERE dispatched with rc 3 (a row that took no
# rung), instead of `dispatched 0 of <k>`.
#
# THE MISREAD (comment 6776463505 on #9369): `dispatched 0 of 3 hand-off(s)`
# on a tick that dispatched 2 rows with rc 3 reads as "nothing was looked at".
# The new text is `<k> undispatched hand-off(s) (<d> dispatched with rc 3)`.
#
#   W1  2 rows acked this tick + 3 unacked, a 0-rung tick: the alert line and
#       the say line carry `3 undispatched hand-off(s) (2 dispatched with rc 3)`,
#       and no line carries `dispatched 0 of`.
#   W2  observe mode: the same text, no alert line.
#   W3  a row acked BEFORE the tick counts as undispatched, not dispatched.
#   W4  a row listed twice and acked counts once in d.
#   W5  every row acked: no line (the k>0 gate is unchanged).
#
# The rig is the pure Z rig of tests/resolver-project-floor.bh-9253-test.sh:
# the real fragment and the real bin/lib/handoff-watch.sh in a scratch
# harness, and every ack is written by the real writer (bhw_ack) under the
# BHW_NOW clock seam. The driven 0-rung tick through bin/blocked-resolver.sh is
# that suite's Z1 (it reads `(0 dispatched with rc 3)`).
# 0 network calls: no vendor binary is called.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/br-zero-dispatch-wording.bh-9467-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
# ONE clock read for the whole file (bin/test-determinism-lint.sh).
NOW=$(date -u +%s)
export GH_TOKEN=""

ZH="$T/zh"
mkdir -p "$ZH/bin" "$ZH/state/blocked-resolver/handoffs/acks"
scratch_install_closure bin/blocked-resolver.d/bh-9253-project-floor.sh "$ZH" >/dev/null \
  || { echo "FAIL: closure install (fragment)"; exit 1; }
scratch_install_closure bin/lib/handoff-watch.sh "$ZH" >/dev/null \
  || { echo "FAIL: closure install (handoff-watch)"; exit 1; }
[ -f "$ZH/bin/blocked-resolver.d/bh-9253-project-floor.sh" ] && [ -f "$ZH/bin/lib/handoff-watch.sh" ] \
  || { echo "FAIL: the fragment or the hand-off lib is not in the scratch harness"; exit 1; }
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/alerts"\n' "$ZH" > "$ZH/bin/alert-line.sh"; chmod +x "$ZH/bin/alert-line.sh"
ACKS="$ZH/state/blocked-resolver/handoffs/acks"

# zw <OBS> <before-acks> <this-tick-acks> [extra-row-tkey]
#   CANDS: five tproj rows, tkeys TK-1..TK-5 (one PR url each), N=0.
#   <before-acks> "TK-1:dispatched ..." are written at NOW-600, then the tick
#   begins at NOW, then <this-tick-acks> are written at NOW. A 4th arg adds a
#   second copy of that row to CANDS.
zw() {
  : > "$ZH/alerts"; : > "$ZH/say"; rm -f "$ACKS"/*
  env OBS="$1" BEFORE="$2" DURING="$3" DUP="${4:-}" TNOW="$NOW" H="$ZH" HARNESS="$ZH" bash -c '
    say() { printf "%s\n" "$*" >> "$H/say"; }
    . "$H/bin/lib/handoff-watch.sh" || exit 1
    . "$H/bin/blocked-resolver.d/bh-9253-project-floor.sh" || exit 1
    lane_project_held() { return 1; }
    url() { printf "https://github.com/o/tproj/pull/%s" "${1#TK-}"; }
    T=$(printf "\t")
    CANDS=()
    for n in 1 2 3 4 5; do
      CANDS+=("conductor${T}tproj${T}k$n${T}r${T}$(url "TK-$n")${T}-${T}TK-$n${T}$((900 - n))")
    done
    [ -n "$DUP" ] && CANDS+=("conductor${T}tproj${T}k${DUP#TK-}${T}r${T}$(url "$DUP")${T}-${T}$DUP${T}800")
    for a in $BEFORE; do BHW_NOW=$((TNOW - 600)) bhw_ack tproj "${a%%:*}" "$(url "${a%%:*}")" "${a#*:}"; done
    BHW_NOW="$TNOW" bhw_tick_begin
    for a in $DURING; do BHW_NOW="$TNOW" bhw_ack tproj "${a%%:*}" "$(url "${a%%:*}")" "${a#*:}"; done
    BHW_ON=1; N=0; EFF_PER_TICK=50; STOPREASON=drained; VISITLIST=""; ONLY=""; OBSERVE="$OBS"
    brpf_init; brpf_zero_alert' 2>>"$ZH/stderr"
}
ALLTXT() { cat "$ZH/alerts" "$ZH/say" 2>/dev/null; }

# W1 — 2 acked this tick (dispatched, acted) + 3 unacked.
zw 0 "" "TK-1:dispatched TK-2:acted"
[ "$(grep -c . "$ZH/alerts")" = 1 ] && ok || bad "W1 one alert line, got: [$(cat "$ZH/alerts")]"
grep -qF -- '--id br-zero-dispatch:fleet [blocked-resolver] fleet: this tick ran 0 rungs and 3 undispatched hand-off(s) (2 dispatched with rc 3) (rungs=0/50 reason=drained' "$ZH/alerts" && ok \
  || bad "W1 the alert line carries the new count text: [$(cat "$ZH/alerts")]"
grep -qF 'oldest: tproj-TK-5' "$ZH/alerts" && ok || bad "W1 oldest: is unchanged (the lowest epoch of the unacked rows): [$(cat "$ZH/alerts")]"
grep -qF 'ZERO_DISPATCH fleet: this tick ran 0 rungs and 3 undispatched hand-off(s) (2 dispatched with rc 3) (rungs=0/50 reason=drained); one br-zero-dispatch alert line' "$ZH/say" && ok \
  || bad "W1 the say line carries the new count text: [$(cat "$ZH/say")]"
W1ALL=$(ALLTXT)
grep -q 'dispatched 0 of' <<<"$W1ALL" && bad "W1 no line says 'dispatched 0 of': [$W1ALL]" || ok

# W2 — observe mode: the same text, no alert.
zw 1 "" "TK-1:dispatched TK-2:lock-held"
[ ! -s "$ZH/alerts" ] && ok || bad "W2 observe mode writes no alert: [$(cat "$ZH/alerts")]"
grep -qF 'ZERO_DISPATCH fleet: this tick ran 0 rungs and 3 undispatched hand-off(s) (2 dispatched with rc 3) (observe mode: no alert written)' "$ZH/say" && ok \
  || bad "W2 the observe say line carries the new count text: [$(cat "$ZH/say")]"
W2ALL=$(ALLTXT)
grep -q 'dispatched 0 of' <<<"$W2ALL" && bad "W2 no line says 'dispatched 0 of': [$W2ALL]" || ok

# W3 — TK-1 acked before the tick, TK-2 acked this tick (held).
zw 0 "TK-1:dispatched" "TK-2:held"
grep -qF 'this tick ran 0 rungs and 4 undispatched hand-off(s) (1 dispatched with rc 3)' "$ZH/alerts" && ok \
  || bad "W3 an ack from before the tick counts as undispatched: [$(cat "$ZH/alerts")]"

# W4 — TK-1 listed twice and acked: d counts it once.
zw 0 "" "TK-1:dispatched TK-2:dispatched" TK-1
grep -qF '3 undispatched hand-off(s) (2 dispatched with rc 3)' "$ZH/alerts" && ok \
  || bad "W4 a row listed twice counts once in d: [$(cat "$ZH/alerts")]"

# W5 — every row acked: no line at all.
zw 0 "" "TK-1:dispatched TK-2:dispatched TK-3:acted TK-4:held TK-5:lock-held"
[ ! -s "$ZH/alerts" ] && ok || bad "W5 every row acked: no alert: [$(cat "$ZH/alerts")]"
W5SAY=$(cat "$ZH/say")
grep -q 'ZERO_DISPATCH' <<<"$W5SAY" && bad "W5 every row acked: no ZERO_DISPATCH line: [$W5SAY]" || ok

[ -s "$ZH/stderr" ] && echo "note: stderr of the rig: $(head -3 "$ZH/stderr")"
echo "br-zero-dispatch-wording.bh-9467: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
