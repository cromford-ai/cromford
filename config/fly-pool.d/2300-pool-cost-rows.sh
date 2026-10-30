# >>> pool cost rows (2026-09-14)
# THE MACHINE'S BILL, LANDED EVEN WHEN THE MACHINE DID NOT (2026-09-14).
# fly/builder-runner.sh mirrors a live machine's logs/cost.csv into cost_rows
# every COST_ROWS_PUSH_S seconds and once more at every terminal path. This is
# the backstop for the one case that loop cannot cover: a machine SIGKILLed,
# OOM'd or stopped between its last push and its RESULT. The reap has already
# copied that build's cost.csv onto the hub (agent-call.sh tees every row into
# the build dir as it writes it), so the rows exist here — they just need
# sending.
#
# ONE IDENTITY, NEVER THE HUB'S. These rows are pushed under
# pool-<project>-<machine-id>, the exact string fly/entrypoint.sh gave the
# machine, because the PK is (box, row_hash): the same string means the
# machine's own push and this one collapse onto one row, and a different string
# would silently double the pool's bill. The rows are NEVER appended to the
# hub's own logs/cost.csv — that file is the hub's write-ahead log of calls the
# HUB made, and a pool row in it would be counted a second time under box=hub by
# the hub's own 10-minute mirror.
#
# Cursor lives in the build dir, so a re-reap of the same directory sends
# nothing and a partial push resumes. Fail-open: every path returns 0, and the
# dup count in the log line is the evidence that the machine's own loop worked.
push_pool_cost_rows() { # push_pool_cost_rows <build-dir> <box>
  local d="${1:-}" box="${2:-}" out
  [ -s "$d/cost.csv" ] && [ -n "$box" ] || return 0
  [ -x "$HARNESS/bin/cost-rows-push.sh" ] || return 0
  out=$(timeout "${COST_ROWS_REAP_TIMEOUT_S:-120}" "$HARNESS/bin/cost-rows-push.sh" \
          --box "$box" --csv "$d/cost.csv" --cursor "$d/.cost-rows.cursor" 2>/dev/null) || true
  say "cost rows: ${out:-push produced no answer} for $box"
  return 0
}
# <<< pool cost rows
