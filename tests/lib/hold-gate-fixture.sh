# shellcheck shell=bash
# tests/lib/hold-gate-fixture.sh — the pr-open HOLD gate for suites that run a
# slice of the pipeline (BH-6091).
#
# The PR create blocks call RB_HOLD_GATE pr-open (bin/lib/rb/gates.sh), which
# reads the ticket's HOLD through hold_push_verdict and FAILS CLOSED: no reader,
# or an unreadable ticket, opens no PR. That is right in production. A suite
# that slices `# >>> pr create call` (or an outer block) out of the flattened
# pipeline gets neither the gate nor the reader, so every create it drives ends
# as "BUILD_DEFERRED hold unreadable at pr-open" before the code it tests runs.
#
#   hold_gate_fns <rb-all> — print the REAL RB_HOLD_YIELD and RB_HOLD_GATE from
#     the flattened pipeline, plus a hold_push_verdict that answers "clear": the
#     ticket has no HOLD. Prepend it to the slice (or source it first). The gate
#     code that runs is production's; only the ticket read is a fixture.
#     tests/pool-hold-yield.bh-6091-test.sh drives the held and unreadable arms.
#
# Source it with a same-line handler:  . "$DIR/tests/lib/hold-gate-fixture.sh" || exit 1
hold_gate_fns() {
  local f="$1" fn
  for fn in RB_HOLD_YIELD RB_HOLD_GATE; do
    sed -n "/^${fn}(){/,/^}\$/p" "$f"
  done
  printf '%s\n' 'hold_push_verdict(){ printf '"'"'clear\tno HOLD on the ticket (tests/lib/hold-gate-fixture.sh)\n'"'"'; return 0; }'
}
#
#   hold_gate_prepend <rb-all> <slice> — put hold_gate_fns at the top of a slice
#     file, AFTER the suite has checked the slice exists, so that check still
#     reads the pipeline's own text only.
hold_gate_prepend() {
  { hold_gate_fns "$1"; cat "$2"; } > "$2.hg" && mv -f "$2.hg" "$2"
}
