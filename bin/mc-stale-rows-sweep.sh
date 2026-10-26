#!/bin/bash
# bin/mc-stale-rows-sweep.sh — BH-8310: a one-time, hand-run sweep that moves
# the READY and WAIT_CI rows of PRs already memo'd merged or closed out of
# state/merge-conductor/pr-state.tsv's live states.
#
# WHY. Until BH-8310 the conductor's closed probe memo'd a merged PR
# (state/merge-conductor/closed-watch/<slug>/<num> = `merged`) and wrote no row,
# so the row stayed READY or WAIT_CI for good. On bh-hub-2, 2026-10-25, #912
# (merged 2026-09-18) was the oldest READY row and took every backstop fire.
# The conductor now settles such rows itself (mc_settle_offlist_rows in
# bin/lib/mc/settle.sh, called from tick_project). This sweep clears the
# backlog at once, with an audit line per row, instead of over the next ticks.
#
# USAGE
#   bin/mc-stale-rows-sweep.sh            dry run: prints what it would move, writes nothing
#   bin/mc-stale-rows-sweep.sh --apply    moves the rows (mc_transition, one log line each)
#
# It is dry-run unless --apply. It makes 0 GitHub calls: it reads only
# pr-state.tsv and the closed-watch memos. A row with no memo, an `open` memo or
# a `gone` (404) memo is not moved; the conductor's own probe handles those.
# No conductor_settle runs: no issue close, no deploy request, no page.
# One line per row: `STALE-ROW <key> <state> -> <target> memo=<word> (<mode>)`,
# then `stale-rows-sweep: <n> rows, <m> merged, <c> closed (<mode>)`.
# rc 0, or rc 1 when the rows file cannot be read.
set -uo pipefail
HARNESS="${HARNESS:-${H:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)}}"
[ -n "$HARNESS" ] || { echo "mc-stale-rows-sweep: no harness root" >&2; exit 1; }
export HARNESS; H="$HARNESS"
MODE=dry
case "${1:-}" in
  --apply) MODE=apply ;;
  ''|--dry-run) ;;
  -h|--help) awk 'NR > 1 && !/^#/ { exit } NR > 1' "$0"; exit 0 ;;
  *) echo "usage: bin/mc-stale-rows-sweep.sh [--apply]" >&2; exit 2 ;;
esac
. "$H/bin/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-$H}/env"; }; HENV=$(harness_env_dir "$H")
set -a; . "$HENV/global.env" 2>/dev/null; set +a
# The pr_state ledger mirror (mc_ledger_put) needs the jobs client, as in the conductor.
# shellcheck source=bin/jobs-client.sh
[ -r "$H/bin/jobs-client.sh" ] && . "$H/bin/jobs-client.sh"
# shellcheck source=bin/lib/merge-conductor-lib.sh
. "$H/bin/lib/merge-conductor-lib.sh" || { echo "mc-stale-rows-sweep: cannot load bin/lib/merge-conductor-lib.sh" >&2; exit 1; }
# The memo store; same path as bin/merge-conductor.sh sets.
MC_CLOSED_WATCH_DIR="${MC_CLOSED_WATCH_DIR:-$MC_STATE_DIR/closed-watch}"
[ -r "$MC_ROWS" ] && [ -f "$MC_ROWS" ] || { echo "mc-stale-rows-sweep: cannot read $MC_ROWS" >&2; exit 1; }
mkdir -p "$MC_H/logs" 2>/dev/null
# No keyed tick (so no probe) and no project lock: these PRs are merged or
# closed, and a keyed settle that races this one writes the same target.
MC_ONLY_KEYS=""; P=""
OUT=$(mktemp "${TMPDIR:-/tmp}/mc-sweep.XXXXXX") || exit 1
while IFS= read -r slug; do
  [ -n "$slug" ] || continue
  mc_settle_offlist_rows "$slug" "" "$MODE" >> "$OUT"
done < <(awk -F'\t' '$1 ~ /^[^#[:space:]]+#[0-9]+$/ { s = $1; sub(/#[0-9]+$/, "", s); if (!seen[s]++) print s }' "$MC_ROWS")
cat "$OUT"
n=$(grep -cE ' -> (MERGED|CLOSED) .*\((dry-run|applied)\)$' "$OUT" || true)
m=$(grep -cE ' -> MERGED .*\((dry-run|applied)\)$' "$OUT" || true)
c=$(grep -cE ' -> CLOSED .*\((dry-run|applied)\)$' "$OUT" || true)
rm -f "$OUT"
echo "stale-rows-sweep: $n rows, $m merged, $c closed ($MODE)"
[ "$MODE" = apply ] && mc_log "stale-rows-sweep: $n rows, $m merged, $c closed (applied)"
exit 0
