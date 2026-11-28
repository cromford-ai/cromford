#!/bin/bash
# bin/lib/fc-contract-change.sh — a contract-change master files its 3 step
# children (BH-9929). Sourced by the `# >>> contract-change hook (BH-9929)`
# block of bin/lib/rb/plan.sh. Never executed; no side effect at source time.
#
# A contract-change ticket (bin/lib/contract-change.sh cc_is_ticket) is never
# planned whole. It is a fixed sequence: expand, migrate, contract, each a PR
# with its own gate (bin/contract-change-gate.sh) and its own verdict. So the
# master files those 3 children here and builds nothing itself, like a rollout
# master. The filing goes through the ONE child-filing contract,
# bin/lib/file-children.sh `file_children ... --kind rollout`:
#   - titles `<KEY>.1`, `.2`, `.3` (a numbered child is never re-split, and the
#     queue, the unblock and the parent-close readers all know the shape)
#   - `Part of #<parent>`, `Order: <n> of 3`
#   - `Blocked-by: #<previous> (hard)` on migrate and contract, from `after`
#   - children.txt is the watermark: a child is on the record only after the
#     tracker returned its number, and a rerun files only the missing steps
#   - the master loses `ai-build`, so no builder picks the whole thing up again
# Each child body carries `Contract-parent: #<parent>` and
# `Contract-step: <step>` (the lines cc_step_of / cc_parent_of read), the
# step's rules, and the parent's body as its scope.
#
# The RESULT words are the rollout lane's own (`ROLLOUT_FILED <n>`,
# `ROLLOUT_FAILED <why>`), because every reader of a filed master — the triage
# prompts, split-chain, the gate release, the ticket lock — already knows them.
#
#   cc_file_steps <project> <parent> <KEY> <build-dir>
#     prints one line `ROLLOUT_FILED 3` (rc 0) or `ROLLOUT_FAILED contract-change: <why>` (rc 1)

CC_STEPS="expand migrate contract"

# cc_step_rules <step> — the rules of one step, as the child body states them.
cc_step_rules() {
  case "${1:-}" in
    expand) cat <<'EOF'
This is the EXPAND step. Add the new shape and write to both shapes. Do not remove or change anything that exists: every migration statement must pass the additive-only gate (bin/check-migration-appliable.sh). The old shape stays readable.
EOF
    ;;
    migrate) cat <<'EOF'
This is the MIGRATE step. Backfill the new shape with a script that is idempotent and resumable (its header says both words). Switch every read to the new shape. Migration SQL stays additive.
The build writes these lines to $BUILD/contract-step.md, and they go into the PR body:
- `BACKFILL-SCRIPT: <path>`
- `BACKFILL-COUNTS: before=<n> after=<n>`
- `OLD-SHAPE: <old table or column name>[, <name>]`
- `OLD-SHAPE-READS: grep=0 query-log=0 window=<h>h` (window at least the registry setting CONTRACT_CHANGE_QUERY_LOG_WINDOW_H)
- optional `OLD-SHAPE-WRITERS: <path>[, <path>]` (files that still write the old shape; stop those writes in an ordinary PR, merged before the contract step)
EOF
    ;;
    contract) cat <<'EOF'
This is the CONTRACT step. Remove the old shape (the DROP, the constraint change, the rename). Carry migration SQL only: main must already have 0 reads and 0 writes of the old shape, and the merge that removed the last one must be at least CONTRACT_CHANGE_QUERY_LOG_WINDOW_H hours old. Before the PR: take a backup and run its restore one time against a scratch database.
The build writes these lines to $BUILD/contract-step.md, and they go into the PR body:
- `BACKUP: <the backup or snapshot reference: a Turso database branch or dump, or a pg_dump of the affected tables in owned storage>`
- `RESTORE-TESTED: <the restore command> -> <the scratch database> rc 0`
- `OLD-SHAPE-READS: grep=0 query-log=0 window=<h>h` (when the step drops or renames a table or column: the production query log over the window shows 0 reads)
- optional `BACKFILL-SCRIPT: <path>` (the migrate step's backfill script on main; the grep skips it)
A DROP TABLE, a DROP COLUMN, a merge of two tables or a column TYPE change needs the owner's human verdict before merge.
EOF
    ;;
  esac
}

cc_file_steps() {
  local project="${1:-}" parent="${2:-}" key="${3:-}" build="${4:-}"
  local h title body spec i s n rc=0 k
  h="${HARNESS:-${H:-}}"
  _ccf_fail() { printf 'ROLLOUT_FAILED contract-change: %s\n' "$*"; return 1; }
  [ -n "$project" ] && [ -n "$parent" ] && [ -n "$key" ] && [ -d "$build" ] || { _ccf_fail "usage: cc_file_steps <project> <parent> <KEY> <build-dir>"; return 1; }
  [ -s "$build/ticket-meta.json" ] || { _ccf_fail "no ticket-meta.json in $build"; return 1; }
  spec="$build/children.json"
  k=$(grep -c '[^[:space:]]' "$build/children.txt" 2>/dev/null || true)
  case "${k:-}" in ''|*[!0-9]*) k=0 ;; esac
  if [ "$k" -ge 3 ] && [ -s "$spec" ]; then
    printf 'ROLLOUT_FILED 3\n'; return 0
  fi
  if [ "$k" -gt 0 ] && [ -s "$spec" ]; then
    : # resume: the same spec, the filer files only the missing steps
  else
    title=$(jq -r '.title // ""' "$build/ticket-meta.json" 2>/dev/null)
    body=$(jq -r '.body // ""' "$build/ticket-meta.json" 2>/dev/null)
    [ -n "${title//[[:space:]]/}" ] || title="contract change"
    i=0
    for s in $CC_STEPS; do
      i=$((i + 1))
      jq -n --arg t "$s — $title" --argjson i "$i" \
        --arg b "$(printf 'Contract-parent: #%s\nContract-step: %s\n\n%s\n\n## Scope (from #%s)\n\n%s\n' \
                   "$parent" "$s" "$(cc_step_rules "$s")" "$parent" "$body")" \
        '{title:$t, body:$b, after:(if $i > 1 then [$i - 1] else [] end)}'
    done | jq -s '.' > "$spec.tmp" 2>/dev/null && mv "$spec.tmp" "$spec" \
      || { rm -f "$spec.tmp"; _ccf_fail "could not write $spec"; return 1; }
  fi
  # shellcheck source=bin/lib/file-children.sh
  if ! command -v file_children >/dev/null 2>&1; then
    if [ -r "$(dirname "${BASH_SOURCE[0]}")/file-children.sh" ]; then . "$(dirname "${BASH_SOURCE[0]}")/file-children.sh"
    elif [ -n "$h" ] && [ -r "$h/bin/lib/file-children.sh" ]; then . "$h/bin/lib/file-children.sh"; fi
  fi
  command -v file_children >/dev/null 2>&1 || { _ccf_fail "bin/lib/file-children.sh is missing"; return 1; }
  file_children "$project" "$parent" "$key" "$build" "$spec" --kind rollout || rc=$?
  # THE RESULT COMES FROM THE RECORD, never from the filer's rc (the rollout
  # lane's rule): filed means children.txt holds 3 tracker numbers.
  n=$(grep -c '[^[:space:]]' "$build/children.txt" 2>/dev/null || true)
  case "${n:-}" in ''|*[!0-9]*) n=0 ;; esac
  if [ "$rc" = 3 ]; then _ccf_fail "the child filer is unavailable"; return 1; fi
  if [ "$n" -lt 3 ]; then _ccf_fail "filed $n of 3 steps (filer rc=$rc; the next run resumes)"; return 1; fi
  if [ "$rc" != 0 ]; then _ccf_fail "filer error rc=$rc after 3 steps were recorded"; return 1; fi
  printf 'ROLLOUT_FILED 3\n'
  return 0
}
