#!/bin/bash
# shellcheck shell=bash
# bin/lib/ci-push-direct.sh — BH-6746 (wave 3 of #6541): the `push-direct`
# event class of bin/ci-plan.sh. Sourced by bin/ci-plan.sh, never run.
#
# WHAT IT IS. A push to main whose head the merge conductor landed DIRECTLY
# (optimistic landing, BH-6745) was tested by nobody on that tree: the merge
# queue never saw it. Today such a push runs the full corpus. This class runs
# the merge's impact set instead: `bin/test-impact.sh select --changed` over
# the merge's first-parent diff (map rows, the always set and the learned `*`
# whole-repo rows), unioned with `bin/test-impact.sh always`. It is never the
# full corpus and never fast-only (corpus=1).
#
# HOW CI KNOWS. A runner cannot read the jobs ledger. The conductor mirrors the
# ledger's `path=direct` mark onto GitHub as the commit status
# `landing-path=success`, description `path=direct`, on the merge sha
# (landing_path_publish in bin/lib/mc/landing.sh, from the same predicate as
# the ledger row). cpd_landed reads that status.
#
# cpd_landed
#   rc 0 when the NEWEST `landing-path` status on $CI_SHA has state `success`
#   and description `path=direct` (the API lists statuses newest first). Reads
#   `${CI_PLAN_GH:-gh} api repos/$CI_REPO/commits/$CI_SHA/statuses?per_page=100`
#   with the job's own token. Sets CPD_WHY on every answer.
#     - no CI_REPO or CI_SHA, no gh, a read that fails or does not parse:
#       rc 1 at once, `landing mark unreadable (<why>)`. No poll.
#     - a newest `landing-path` that is anything else: rc 1 at once.
#     - no `landing-path` status yet: poll every CI_PLAN_DIRECT_POLL_S seconds
#       (default 10) until CI_PLAN_DIRECT_WAIT_S (default 120) have passed,
#       because the conductor's settle can post a few seconds after the push.
#       Then rc 1, `no direct-landing mark on <sha8> after <n>s`.
#   A knob that is not a positive integer uses its default and says so.
#
# cpd_select
#   Builds $CH (CI_PLAN_CHANGED_FILE, else `git diff --no-renames --name-only
#   HEAD^1 HEAD`) and sets MODE, REASON and $LIST. It ESCALATES to the full
#   corpus (MODE=full, `TI_EVENT=push ci-select`, the reason given) on: a diff
#   that cannot be read or is empty, a path catalog/ci-batch-escalate.tsv names
#   (cbe_reason; rules that cannot be read escalate too), test-impact's own
#   `full:` answer, an always set that cannot be read, or a selection of every
#   suite. Else MODE=push-direct. A failed test-impact call is rc 2 (exit),
#   never a smaller run. It makes no network call, so a shard
#   (CI_PLAN_PUSH_CLASS=push-direct) plans the same list as the plan job.
#
# Reads bin/ci-plan.sh's globals: ROOT, SELF_DIR, IMPACT, TMP, LIST, WHY and
# its impact_reason function.
# gh-rest: no-graphql

# _cpd_knob <name> <default> — a positive integer, or the default, said out loud.
_cpd_knob() {
  local v="${!1:-}"
  case "$v" in
    '') echo "$2" ;;
    *[!0-9]*|0) echo "ci-plan: $1='$v' is not a positive integer — using $2" >&2; echo "$2" ;;
    *) echo "$v" ;;
  esac
}

cpd_landed() {
  local gh="${CI_PLAN_GH:-gh}" repo="${CI_REPO:-}" sha="${CI_SHA:-}" wait poll waited=0 j st desc
  CPD_WHY=""
  wait=$(_cpd_knob CI_PLAN_DIRECT_WAIT_S 120); poll=$(_cpd_knob CI_PLAN_DIRECT_POLL_S 10)
  [ -n "$repo" ] && [ -n "$sha" ] || { CPD_WHY="landing mark unreadable (no repository or sha to ask)"; return 1; }
  command -v "$gh" >/dev/null 2>&1 || { CPD_WHY="landing mark unreadable (gh is not on this runner)"; return 1; }
  while :; do
    j=$("$gh" api "repos/$repo/commits/$sha/statuses?per_page=100" 2>/dev/null) \
      || { CPD_WHY="landing mark unreadable (the statuses of ${sha:0:8} could not be read)"; return 1; }
    # The newest landing-path entry, as `<state>\t<description>`; none is "".
    st=$(jq -r 'if type == "array" then ([.[] | select(.context? == "landing-path")][0]
                  | if . == null then "" else "\(.state // "")\t\(.description // "")" end)
                else error("not a list") end' <<<"$j" 2>/dev/null) \
      || { CPD_WHY="landing mark unreadable (the statuses of ${sha:0:8} did not parse)"; return 1; }
    if [ -n "$st" ]; then
      desc="${st#*$'\t'}"
      if [ "${st%%$'\t'*}" = success ] && [ "$desc" = "path=direct" ]; then
        CPD_WHY="direct-landing mark on ${sha:0:8}"; return 0
      fi
      CPD_WHY="landing-path on ${sha:0:8} is ${st%%$'\t'*} '$desc', not success 'path=direct'"; return 1
    fi
    [ "$waited" -lt "$wait" ] || break
    sleep "$poll"; waited=$((waited + poll))
  done
  CPD_WHY="no direct-landing mark on ${sha:0:8} after ${waited}s"
  return 1
}

# _cpd_full <why> — the escalation: the real corpus, today's full branch.
_cpd_full() {
  MODE=full
  TI_EVENT=push "$IMPACT" ci-select --out "$LIST" 2>"$WHY" \
    || { echo "ci-plan: bin/test-impact.sh ci-select failed: $(cat "$WHY")" >&2; exit 2; }
  REASON="full: a direct-landed push that escalates ($1)"
}

cpd_select() {
  local esc="" p r k sel tot base
  CH="$TMP/changed"
  if [ -n "${CI_PLAN_CHANGED_FILE:-}" ]; then
    cp "$CI_PLAN_CHANGED_FILE" "$CH" 2>/dev/null || { : > "$CH"; esc="the changed list could not be read"; }
  # --no-renames: a rename names its old AND new path, as in a batch.
  else
    git -C "$ROOT" diff --no-renames --name-only HEAD^1 HEAD > "$CH" 2>/dev/null \
      || { : > "$CH"; esc="cannot diff the merge from its first parent"; }
  fi
  [ -n "$esc" ] || grep -q . "$CH" || esc="the merge's first-parent diff is empty"
  if [ -z "$esc" ]; then
    if ! . "$SELF_DIR/lib/ci-batch-escalate.sh" 2>/dev/null || ! command -v cbe_reason >/dev/null 2>&1; then
      esc="the escalation rules could not be read"
    else
      while IFS= read -r p; do
        [ -n "$p" ] || continue
        if r=$(cbe_reason "$p"); then esc="$r"; break; fi
      done < "$CH"
    fi
  fi
  [ -z "$esc" ] || { _cpd_full "$esc"; return 0; }
  base=$(git -C "$ROOT" rev-parse -q --verify 'HEAD^1^{commit}' 2>/dev/null) || base=""
  TI_NAMED_BASE="$base" "$IMPACT" select --changed "$CH" --out "$LIST" 2>"$WHY" \
    || { echo "ci-plan: bin/test-impact.sh select failed: $(cat "$WHY")" >&2; exit 2; }
  r=$(impact_reason "$WHY") || exit 2
  case "$r" in "full: "*) _cpd_full "${r#full: }"; return 0 ;; esac
  tot=$(sed -n 's/^impact: [0-9]* of \([0-9]*\) suites.*/\1/p' "$WHY" | tail -1)
  "$IMPACT" always > "$TMP/cpd.always" 2>/dev/null || { _cpd_full "the always set could not be read"; return 0; }
  LC_ALL=C sort -u "$LIST" "$TMP/cpd.always" | grep . > "$TMP/cpd.union"
  cp "$TMP/cpd.union" "$LIST" || { echo "ci-plan: cannot write the push-direct list" >&2; exit 2; }
  sel=$(grep -c . "$LIST")
  if [ -n "$tot" ] && [ "${sel:-0}" -ge "$tot" ]; then _cpd_full "the selection is every suite"; return 0; fi
  k=$(grep -c . "$CH")
  # ci-plan's summary line re-reads the total from $WHY's last `impact:` line.
  MODE=push-direct
  REASON="push-direct: ${CPD_WHY:-direct-landing mark}: impact of $k changed path(s) + always + whole-repo ($r)"
}
