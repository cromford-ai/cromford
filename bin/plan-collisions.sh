#!/bin/bash
# bin/plan-collisions.sh — check the symbols a plan changes against main since
# the plan's base and against every open PR (BH-5791). The logic is in
# bin/lib/plan-collisions.sh; the `design collisions` block in
# bin/lib/rb/plan.sh runs this after the plan gate.
#
# usage: plan-collisions.sh --plan F --repo D --base SHA --main REF --out F
#          [--slug OWNER/REPO] [--self-branch B] [--self-key K]
#          [--stack-base B] [--project P]
#
# Writes <out>:
#   SYMBOLS: listed=<n> derived=<m> dropped=<d> cap=<c>
#   MAIN: checked <base12>..<main12> | unread (<why>)
#   OPEN_PRS: checked <k> | unread (<why>) | off
#   SYMBOL<TAB>listed|derived<TAB><kind><TAB><name><TAB><reason>
#   COLLISION<TAB>listed|derived<TAB><name><TAB>main|#<n><TAB><sha12><TAB><reason>
# and prints one summary line:
#   COLLISIONS: hits=<h> listed=<l> derived=<d> main=<checked|unread> prs=<checked:k|unread|off>
# rc 0 = no collision, 1 = collisions, 3 = could not run (bad arguments, no
# plan, not a git repo). An unread main or PR list is rc 0/1, never 3: what
# was read is still reported, and the state lines say what was not.
set -uo pipefail
PLAN="" REPO="" BASE="" MAIN="" OUT="" SLUG="" SELF="" SELFKEY="" STACK="" PROJECT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --plan) PLAN="${2:-}"; shift 2 ;;
    --repo) REPO="${2:-}"; shift 2 ;;
    --base) BASE="${2:-}"; shift 2 ;;
    --main) MAIN="${2:-}"; shift 2 ;;
    --out) OUT="${2:-}"; shift 2 ;;
    --slug) SLUG="${2:-}"; shift 2 ;;
    --self-branch) SELF="${2:-}"; shift 2 ;;
    --self-key) SELFKEY="${2:-}"; shift 2 ;;
    --stack-base) STACK="${2:-}"; shift 2 ;;
    --project) PROJECT="${2:-}"; shift 2 ;;
    *) echo "COLLISIONS: could-not-run (unknown argument $1)"; exit 3 ;;
  esac
done
fail() { echo "COLLISIONS: could-not-run ($1)"; exit 3; }
[ -n "$PLAN" ] && [ -r "$PLAN" ] || fail "no readable plan"
[ -n "$OUT" ] || fail "no --out"
[ -n "$REPO" ] && git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1 || fail "not a git repo"
[ -n "$MAIN" ] || fail "no --main"
# shellcheck source=bin/lib/plan-collisions.sh
. "$(dirname "$0")/lib/plan-collisions.sh" || fail "lib missing"
pc_conf "$PROJECT"
[ -z "$PC_CONF_WARN" ] || echo "plan-collisions: $PC_CONF_WARN" >&2

# Planning can take twenty minutes, so main is fetched again here.
case "$MAIN" in origin/*) git -C "$REPO" fetch --quiet origin "${MAIN#origin/}" 2>/dev/null || true ;; esac

SYMS=$(mktemp "${TMPDIR:-/tmp}/pc-syms.XXXXXX") || fail "no temp file"
ROWS=$(mktemp "${TMPDIR:-/tmp}/pc-rows.XXXXXX") || { rm -f "$SYMS"; fail "no temp file"; }
trap 'rm -f "$SYMS" "$ROWS" "$SYMS.all"' EXIT
# Derived names are located at the base when it resolves, else at main.
REF="$MAIN"
[ -n "$BASE" ] && git -C "$REPO" cat-file -e "$BASE^{commit}" 2>/dev/null && REF="$BASE"
pc_symbols "$PLAN" "$REPO" "$REF" > "$SYMS.all" || fail "could not parse the plan"
TOTAL=$(grep -c . "$SYMS.all")
awk -v m="$PC_MAX_SYMBOLS" 'NR <= m' "$SYMS.all" > "$SYMS"
DROPPED=$((TOTAL - $(grep -c . "$SYMS")))
NL=$(grep -c '^listed' "$SYMS"); ND=$(grep -c '^derived' "$SYMS")

MAIN_STATE=checked
if [ -z "$BASE" ]; then
  MAIN_LINE="unread (no base)"; MAIN_STATE=unread
elif pc_main_hits "$REPO" "$BASE" "$MAIN" "$SYMS" "$ROWS"; then
  MAIN_LINE="checked $(git -C "$REPO" rev-parse --short=12 "$BASE" 2>/dev/null)..$(git -C "$REPO" rev-parse --short=12 "$MAIN" 2>/dev/null)"
else
  MAIN_LINE="unread ($PC_WHY)"; MAIN_STATE=unread
fi

PR_RC=0
pc_pr_hits "$REPO" "$MAIN" "$SYMS" "$ROWS" "$SLUG" "$SELF" "$SELFKEY" "$STACK" "$PC_MAX_PRS" || PR_RC=$?
# BH-9944: one line for the build's pipeline.log (the caller appends stderr).
echo "plan-collisions: open PRs read=$PC_PR_N prefilter=$PC_PREFILTER pc_hit calls=$PC_PF_CALLS skipped=$PC_PF_SKIPPED" >&2
case "$PR_RC" in
  0) PR_LINE="checked $PC_PR_N"; PR_STATE="checked:$PC_PR_N" ;;
  4) PR_LINE="off"; PR_STATE=off ;;
  *) PR_LINE="unread ($PC_WHY)"; PR_STATE=unread ;;
esac

{
  printf 'SYMBOLS: listed=%s derived=%s dropped=%s cap=%s\n' "$NL" "$ND" "$DROPPED" "$PC_MAX_SYMBOLS"
  printf 'MAIN: %s\n' "$MAIN_LINE"
  printf 'OPEN_PRS: %s\n' "$PR_LINE"
  awk -F'\t' '{ printf "SYMBOL\t%s\t%s\t%s\t%s\n", $1, $2, $3, $4 }' "$SYMS"
  awk -F'\t' '!s[$2 SUBSEP $3 SUBSEP $4]++' "$ROWS"
} > "$OUT" || fail "cannot write --out"

H_ALL=$(grep -c '^COLLISION	' "$OUT"); H_L=$(grep -c '^COLLISION	listed	' "$OUT")
printf 'COLLISIONS: hits=%s listed=%s derived=%s main=%s prs=%s\n' "$H_ALL" "$H_L" "$((H_ALL - H_L))" "$MAIN_STATE" "$PR_STATE"
[ "$H_ALL" = 0 ] && exit 0
exit 1
