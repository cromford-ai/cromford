#!/bin/bash
# bin/lib/review-tier.sh — how deeply this diff gets reviewed, decided from the
# diff itself, deterministically, before a single lens is launched (BH-485).
#
#   . bin/lib/review-tier.sh          -> defines review_tier / review_tier_cap
#   review_tier <base> <head>         -> prints exactly one line:
#                                          T0 reason=docs/tests/config only (4 paths)
#                                          T1 reason=product code, no risky paths
#                                          T2 reason=3 risky path(s), 1 schema/money path(s)
#                                          T2 reason=diff-unavailable
#                                          T2 reason=unresolvable path(s)
#   review_tier_files [list-file]     -> the same line over a path list (P4)
#   bin/lib/review-tier.sh <base> <head>   the same line, as a CLI
#
# WHY. Every review lens is a full model read of the diff, and the lens stage is
# 8.5 min median / 35 min p90. A docs change and a schema change were reviewed
# identically. The tier is what buys depth now: T0 gets one lens on a static
# prompt, T1 gets today's set, T2 gets everything and uncapped fix rounds.
#
# ORDER MATTERS AND IS THE POINT. T2 is tested FIRST, so a diff that mixes a
# README with a migration is T2, and a .sql or migrations/ path sitting under
# tests/ can never be read as "docs only". The classifier's whole job is gating
# how much scrutiny reaches a merge, so every unknown answer is T2: an empty or
# unreadable file list, a path this cannot resolve, a git that fails. It fails
# toward MORE review, never toward the cheap tier.
#
# NO SIDE EFFECTS. It reads git, prints one line, and returns 0 on every
# classification. It writes no file, makes no network call, and never exits
# nonzero for a diff it could not classify — that answer is T2, not a crash.
set -uo pipefail

# The two risky-file regexes, COPIED VERBATIM from the lens block of
# bin/run-build.sh (the RISKY= and HIGHRISK= lines). They are copied rather than
# sourced because that block's two lines are the shipped definition and this
# ticket is explicitly not allowed to redefine them; tests/review-tier-test.sh
# section A asserts these two strings are still byte-identical to the ones in
# bin/run-build.sh, so a drift fails a suite instead of quietly tiering a
# webhook change as product code.
RT_RISKY_RE='schema\.prisma|prisma/schema/.+\.prisma$|migrations?/|\.sql$|middleware|auth|permission|role|billing|stripe|tipalti|invoice|payment|payout|token|webhook'
RT_HIGHRISK_RE='schema\.prisma|prisma/schema/.+\.prisma$|migrations?/|\.sql$|billing|stripe|tipalti|invoice|payment|payout'
# T0's own list, from the ticket: docs/, tests/, .github/, any fixtures/ dir, or
# anything ending .md. Anchored at the path root the way git prints it.
RT_DOCS_RE='^docs/|^tests/|^\.github/|(^|/)fixtures/|\.md$'

# One line, no tabs, bounded — it lands in pipeline.log and in a markdown table
# cell on the PR page.
rt_reason() { # rt_reason <text>
  printf '%s' "$1" | tr -d '\000-\010\013\014\016-\037' | tr '\n\r\t|' '   /' | cut -c1-200
}

# review_tier <base> [head] -> "T<n> reason=<text>" on stdout, rc always 0.
review_tier() {
  local base="${1:-}" head="${2:-HEAD}" files
  files=$(git diff --name-only "$base"..."$head" 2>/dev/null)
  _rt_classify "$files" diff-unavailable
}

# review_tier_files [list-file] -> the same one line, over a PATH LIST (one per
# line, from the file or stdin) instead of a git diff. P4's shadow resolver
# (bin/lib/route-rules.sh) asks it about the files a PLAN names before a line
# is written. Same classifier, same order, same fail-toward-T2: an empty or
# unreadable list is `T2 reason=planned-files-unavailable`.
review_tier_files() {
  local files
  if [ -n "${1:-}" ]; then files=$(cat -- "$1" 2>/dev/null); else files=$(cat 2>/dev/null); fi
  _rt_classify "$files" planned-files-unavailable
}

# _rt_classify <newline-separated paths> <reason-when-empty> -> one tier line.
_rt_classify() {
  local files="${1:-}" empty_reason="${2:-diff-unavailable}" n risky high f docs_only=1
  # An empty list is never "nothing risky changed": it is a diff this could not
  # read (bad base, detached ref, not a repo) or a diff with no files at all,
  # and neither one has earned a cheap review.
  if ! grep -q '[^[:space:]]' <<<"$files"; then
    printf 'T2 reason=%s\n' "$empty_reason"
    return 0
  fi
  n=$(printf '%s\n' "$files" | grep -c '[^[:space:]]')

  # A path this cannot resolve is not normalised into a tier — `tests/../bin/`
  # is a bin/ change wearing a tests/ prefix.
  if grep -q '\.\.' <<<"$files"; then
    printf 'T2 reason=unresolvable path(s)\n'
    return 0
  fi

  # Split the list once: what is docs/tests/CI-config, and what is not.
  local product=""
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    grep -qE "$RT_DOCS_RE" <<<"$f" && continue
    docs_only=0
    product="$product$f
"
  done <<RT_FILES
$files
RT_FILES

  # The counts bin/run-build.sh's own RISKY= and HIGHRISK= lines produce, over
  # the whole diff. They are what the lens set is built from downstream, so the
  # reason reports these and not some second measurement of the same thing.
  risky=$(printf '%s\n' "$files" | grep -icE "$RT_RISKY_RE") || risky=0
  high=$(printf '%s\n' "$files" | grep -icE "$RT_HIGHRISK_RE") || high=0
  case "$risky" in ''|*[!0-9]*) risky=0 ;; esac
  case "$high"  in ''|*[!0-9]*) high=0 ;; esac

  # WHERE THE TWO CLASSES DIFFER, and why. The schema/money class (HIGHRISK:
  # schema.prisma, prisma/schema/*.prisma, migrations/, .sql, billing/stripe/tipalti/invoice/payment/
  # payout) forces T2 WHEREVER it sits — a .sql fixture under tests/ is still a
  # statement someone can run, and blast radius does not care which directory
  # the file lives in. The name-based risky extras (middleware, auth,
  # permission, role, token, webhook) force T2 only when they name a path that
  # is NOT itself docs/tests/CI-config: `tests/gh-token-test.sh` is a test
  # ABOUT a token, not a change to one, and tiering it as a schema diff would
  # buy two lenses for a file whose own tier says one.
  local risky_product=0
  if [ -n "$product" ]; then
    risky_product=$(printf '%s' "$product" | grep -icE "$RT_RISKY_RE") || risky_product=0
    case "$risky_product" in ''|*[!0-9]*) risky_product=0 ;; esac
  fi
  if [ "$high" -gt 0 ] || [ "$risky_product" -gt 0 ]; then
    printf 'T2 reason=%s\n' "$(rt_reason "$risky risky path(s), $high schema/money path(s)")"
    return 0
  fi

  if [ "$docs_only" = 1 ]; then
    printf 'T0 reason=%s\n' "$(rt_reason "docs/tests/config only ($n paths)")"
  else
    printf 'T1 reason=%s\n' "$(rt_reason "product code, no risky paths")"
  fi
  return 0
}

# review_tier_cap <T0|T1|T2> -> how many lens fix rounds this tier buys.
# review_tier_cap <T0|T1|T2> [project] -> how many lens fix rounds this tier buys.
# T0 1, T1 2. T2 (and an unrecognised tier) reads the settings row
# review.fix_rounds_max[.<project>] through rl_knob (bin/lib/review-level.sh,
# BH-7123 wave B; seeded 2 by wave A), the same row the resolver's review cap
# reads, so a ticket buys the same number of rounds before and after its PR.
# Without that lib on the box the answer is 0, uncapped, which is what every
# tier did before this existed. review.mode cowboy / off buys no round at all;
# that is the caller's FIX_ROUNDS_OFF (bin/lib/rb/review.sh), because 0 here
# means uncapped and bin/evidence-summary.sh reads `cap=N` as a number.
review_tier_cap() {
  local cap
  case "${1:-}" in
    T0) printf '1\n' ;;
    T1) printf '2\n' ;;
    *)  if command -v rl_knob >/dev/null 2>&1; then
          cap=$(rl_knob review.fix_rounds_max "${2:-}" 2 '^[0-9]{1,2}$' 2>/dev/null 7>&- 8>&-)
          case "$cap" in ''|*[!0-9]*) cap=2 ;; esac
          printf '%s\n' "$cap"
        else printf '0\n'; fi ;;
  esac
}

# CLI: bin/lib/review-tier.sh <base> [head]
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  [ $# -ge 1 ] || { echo "usage: review-tier.sh <base> [head]" >&2; exit 2; }
  review_tier "$@"
fi
