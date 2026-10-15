#!/bin/bash
# bin/staff-learn.sh — BH-5563 (BH-5556.6): the replay gate for a staff
# agent's skills. It runs the unchanged bin/archie-learn.sh on the agent's own
# skills tree, so a staff skill changes the way Archie's do: every replay of
# the skill must pass first.
#
#   staff-learn.sh edit    <agent> <skill> <new SKILL.md> [--case <dir>]... --why <text>
#   staff-learn.sh correct <agent> <skill> <new SKILL.md> --case <dir> [--case <dir>]... --why <text>
#   staff-learn.sh propose <agent> <name> <dir>
#   staff-learn.sh adopt   <agent> <name>
#
# <agent> must match ^[a-z][a-z0-9-]{1,39}$, else rc 2. `correct facts`,
# `report` and `unused` are Archie's alone: rc 2. Otherwise this runs
# bin/archie-learn.sh <mode> <args...> with
#   ARCHIE_ORC_DIR    = $HARNESS/state/staff/<agent>/skills-home
#   ARCHIE_SKILLS_SRC = $HARNESS_CHECKOUT/prompts/staff/skills/<agent>
# so the live staff skill is
#   state/staff/<agent>/skills-home/.claude/skills/<skill>/SKILL.md
# and its replays come from the checkout (or the learned copy beside the live
# one). The gate, staging, rollback, lock (locks/archie-learn.lock, flock -n:
# held = rc 3) and model (stage archie-replay) are archie-learn's: a failing
# replay is `rejected`, rc 1, and the live SKILL.md does not change. Events
# land in logs/archie-learning.log, which Archie's weekly report reads.
# Note: docs/notes/2026-10-14-BH-5563-staff-learning.md.
set -uo pipefail
H="${HARNESS:-/root/harness}"
SELF="$(cd "$(dirname "$0")" && pwd)"
usage() { echo "usage: staff-learn.sh <edit|correct|propose|adopt> <agent> <args...>" >&2; exit 2; }
MODE="${1:-}"; AGENT="${2:-}"
case "$MODE" in
  edit|correct|propose|adopt) ;;
  report|unused) echo "staff-learn: $MODE is Archie's (bin/archie-learn.sh $MODE)" >&2; exit 2 ;;
  *) usage ;;
esac
[[ $AGENT =~ ^[a-z][a-z0-9-]{1,39}$ ]] || { echo "staff-learn: bad agent name '$AGENT'" >&2; exit 2; }
[ "$MODE" = correct ] && [ "${3:-}" = facts ] && { echo "staff-learn: correct facts is Archie's" >&2; exit 2; }
shift 2
exec env ARCHIE_ORC_DIR="$H/state/staff/$AGENT/skills-home" \
  ARCHIE_SKILLS_SRC="${HARNESS_CHECKOUT:-/root/harness-checkout}/prompts/staff/skills/$AGENT" \
  bash "$SELF/archie-learn.sh" "$MODE" "$@"
