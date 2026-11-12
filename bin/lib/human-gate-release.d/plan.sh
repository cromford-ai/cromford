# shellcheck shell=bash
# bin/lib/human-gate-release.d/plan.sh — the plan lane's human-gate release
# (BH-9559 part A). hg_release plan <repo> <key> <answer> calls hgr_plan.
#
# hgr_plan <project> <KEY> <answer> [ticket-id] [size] [kind]
#   requeues the ticket through bin/queue-line-put.sh, with the answer in the
#   queue line's reason (one line, first 200 characters). ticket-id defaults
#   to the key's number, size to M, kind to feature. rc = queue-line-put's rc;
#   rc 1 with no HARNESS root.
hgr_plan() {
  local p="${1:-}" key="${2:-}" ans="${3:-}" tid="${4:-}" size="${5:-M}" kind="${6:-feature}" root="${HARNESS:-${H:-}}"
  [ -n "$root" ] && [ -x "$root/bin/queue-line-put.sh" ] || { echo "hgr_plan: no bin/queue-line-put.sh (no HARNESS root)" >&2; return 1; }
  [ -n "$tid" ] || tid="${key##*-}"
  ans=$(printf '%s' "$ans" | tr '\r\n\t' '   ' | tr -s ' ' | sed 's/^ //; s/ $//')
  "$root/bin/queue-line-put.sh" "$p" "$key" "$tid" "$size" "$kind" "human-gate answer (plan): ${ans:0:200}"
}
