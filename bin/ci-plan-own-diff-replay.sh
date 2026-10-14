#!/bin/bash
# bin/ci-plan-own-diff-replay.sh [--last N] [--repo O/R] [--out TSV] — what the
# BH-6490 own-diff escalation rule would have done to the last N merge-queue
# batch drafts. READ-ONLY: GitHub REST reads through `${REPLAY_GH:-gh} api`
# (no gh pr/run/issue subcommand), nothing written but --out.
#
# Per draft (a PR by mergify[bot] whose head ref is mergify/merge-queue/*,
# newest first):
#   1. base.sha, head.sha and the body's `checking_base_sha:` line. A batch is
#      STACKED when there is exactly one and it is not base.sha.
#   2. THE OLD ANSWER: the newest `Harness CI` run for head.sha, the
#      `ci-plan` notice on the "CI plan (what this run tests)" job -> old mode
#      and reason (`unknown` with no notice), and the mean minutes of the
#      "Tests, traced (shard …)" jobs.
#   3. The full diff (compare base...head) and the own diff (compare
#      checking...head; the full diff when not stacked). A compare that fails,
#      or answers 300 files (the API cap), is an `unreadable` row: reported,
#      never counted as narrowed.
#   4. THE NEW ANSWER: the first own path bin/lib/ci-batch-escalate.sh's
#      cbe_reason escalates (an own diff to the rules file counts as
#      escalating: add-only is not proven here), else `select --changed <own>`
#      with TI_BATCH_SELECT=1 through ${REPLAY_IMPACT:-bin/test-impact.sh}.
#      That second step uses THIS checkout's map, not the map of the day, so
#      the output says `approx: current map`.
#
# Row (TSV, header first): draft base8 own8 old_mode old_reason new_class
# new_reason shard_mean_min. new_class is one of
#   own                 the new rule runs the corpus on an own path
#   inherited→selected  the old run was full on a path outside the own diff,
#                       and the own diff does not escalate: narrowed
#   inherited→full      the old trigger was inherited, but the own diff
#                       escalates too: still full
#   full-other          the old run was full for a reason with no path (a
#                       label, member labels, every suite): still full
#   selected            the old run was not full, and the new one is not
#   unreadable          a compare or the selection could not be read
# Then the summary lines: batches read, old full, `inherited-trigger full:
# X -> Y`, `narrowed by the own diff: K`, the old mean shard minutes of the
# narrowed batches and of the window's batch-selected batches, and `full
# fallback still fires: Z of N (own base -: W)`.
#
# rc 0 on a complete read (a batch read failure is an `unreadable` row), rc 2
# when the PR list cannot be read or an argument is wrong.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
GH="${REPLAY_GH:-gh}"
IMPACT="${REPLAY_IMPACT:-$SELF_DIR/test-impact.sh}"
# BH-4080: the repo default is HARNESS_REPO from the deployment defaults home.
# shellcheck source=bin/lib/deployment.sh
. "${HARNESS_DEPLOYMENT_FILE-$SELF_DIR/lib/deployment.sh}" || exit 2
LAST=30; REPO="$HARNESS_REPO"; OUTF=""
while [ $# -gt 0 ]; do
  case "$1" in
    --last) [ $# -ge 2 ] || { echo "replay: --last needs a number" >&2; exit 2; }; LAST="$2"; shift ;;
    --repo) [ $# -ge 2 ] || { echo "replay: --repo needs owner/repo" >&2; exit 2; }; REPO="$2"; shift ;;
    --out)  [ $# -ge 2 ] || { echo "replay: --out needs a path" >&2; exit 2; }; OUTF="$2"; shift ;;
    -h|--help) sed -n '2,43p' "$0"; exit 0 ;;
    *) echo "replay: unknown argument $1" >&2; exit 2 ;;
  esac
  shift
done
case "$LAST" in ''|*[!0-9]*|0) echo "replay: --last must be a positive integer, got '$LAST'" >&2; exit 2 ;; esac
# shellcheck source=lib/ci-batch-escalate.sh
. "$SELF_DIR/lib/ci-batch-escalate.sh" || { echo "replay: cannot read bin/lib/ci-batch-escalate.sh" >&2; exit 2; }
TMP=$(mktemp -d "${TMPDIR:-/tmp}/own-diff-replay.XXXXXX") || { echo "replay: no temp dir" >&2; exit 2; }
trap 'rm -rf "$TMP"' EXIT

# ── The drafts, newest first, up to 10 pages of 100 PRs.
: > "$TMP/drafts"
for pg in 1 2 3 4 5 6 7 8 9 10; do
  j=$("$GH" api "repos/$REPO/pulls?state=all&sort=created&direction=desc&per_page=100&page=$pg" 2>"$TMP/err") \
    || { echo "replay: the PR list could not be read (page $pg): $(head -c 300 "$TMP/err")" >&2; exit 2; }
  jq -c '.[] | select(.user.login == "mergify[bot]" and ((.head.ref // "") | startswith("mergify/merge-queue/")))' <<<"$j" >> "$TMP/drafts" 2>/dev/null \
    || { echo "replay: the PR list did not parse (page $pg)" >&2; exit 2; }
  [ "$(grep -c . "$TMP/drafts")" -lt "$LAST" ] || break
  [ "$(jq 'length' <<<"$j" 2>/dev/null)" -gt 0 ] 2>/dev/null || break
done
head -n "$LAST" "$TMP/drafts" > "$TMP/drafts.n"

# files <base> <head> <out> — the compare's paths (renames as both); rc 1 when
# it cannot be read or hit the 300-file cap.
files() {
  local j
  j=$("$GH" api "repos/$REPO/compare/$1...$2" 2>/dev/null) || return 1
  [ "$(jq '.files | length' <<<"$j" 2>/dev/null)" -lt 300 ] 2>/dev/null || return 1
  jq -r '.files[] | .filename, (.previous_filename // empty)' <<<"$j" 2>/dev/null | LC_ALL=C sort -u > "$3"
}
# old_answer <head> — sets OLD_MODE, OLD_REASON, SHARD_MIN from the run's notice and jobs
old_answer() {
  local runs rid jobs cid ann msg
  OLD_MODE=unknown; OLD_REASON=-; SHARD_MIN=-
  runs=$("$GH" api "repos/$REPO/actions/runs?head_sha=$1&event=pull_request&per_page=20" 2>/dev/null) || return 0
  rid=$(jq -r '[.workflow_runs[]? | select(.name == "Harness CI")][0].id // empty' <<<"$runs" 2>/dev/null)
  [ -n "$rid" ] || return 0
  jobs=$("$GH" api "repos/$REPO/actions/runs/$rid/jobs?per_page=100" 2>/dev/null) || return 0
  SHARD_MIN=$(jq -r '[.jobs[]? | select((.name // "") | startswith("Tests, traced (shard"))
      | select(.started_at and .completed_at)
      | ((.completed_at | fromdateiso8601) - (.started_at | fromdateiso8601)) / 60]
      | if length > 0 then add / length else "-" end' <<<"$jobs" 2>/dev/null)
  case "$SHARD_MIN" in ''|-) SHARD_MIN=- ;; *) SHARD_MIN=$(awk -v m="$SHARD_MIN" 'BEGIN { printf "%.1f", m }') ;; esac
  cid=$(jq -r '[.jobs[]? | select(.name == "CI plan (what this run tests)")][0].check_run_url // empty' <<<"$jobs" 2>/dev/null)
  [ -n "$cid" ] || return 0
  ann=$("$GH" api "repos/$REPO/check-runs/${cid##*/}/annotations" 2>/dev/null) || return 0
  msg=$(jq -r '[.[]? | select(.title == "ci-plan")][0].message // empty' <<<"$ann" 2>/dev/null)
  [ -n "$msg" ] || return 0
  OLD_MODE=$(sed -n 's/^mode=\([^ ]*\) .*/\1/p' <<<"$msg"); OLD_MODE="${OLD_MODE:-unknown}"
  case "$msg" in *" reason="*) OLD_REASON="${msg#* reason=}" ;; esac
}
# trigger <reason> — the path a full reason names, or nothing
trigger() {
  local r="${1#full: }"; r="${r%%; *}"
  case "$r" in
    "selection input: "*) printf '%s\n' "${r#selection input: }" ;;
    "unmapped: "*)        printf '%s\n' "${r#unmapped: }" ;;
    "unmapped path "*)    printf '%s\n' "${r#unmapped path }" ;;
  esac
}

APPROX="approx: current map ($IMPACT)"
printf 'draft\tbase8\town8\told_mode\told_reason\tnew_class\tnew_reason\tshard_mean_min\n' > "$TMP/rows"
while IFS= read -r d; do
  n=$(jq -r .number <<<"$d"); base=$(jq -r .base.sha <<<"$d"); head=$(jq -r .head.sha <<<"$d")
  chk=$(jq -r '.body // ""' <<<"$d" | tr -d '\r' | sed -n 's/^checking_base_sha: \([0-9a-f]\{40\}\)[[:space:]]*$/\1/p' | LC_ALL=C sort -u)
  own=-; [ "$(grep -c . <<<"$chk")" = 1 ] && [ "$chk" != "$base" ] && own="$chk"
  old_answer "$head"
  cls=""; new=""
  if ! files "$base" "$head" "$TMP/full"; then cls=unreadable; new="the full compare could not be read"
  elif [ "$own" = - ]; then cp "$TMP/full" "$TMP/own"
  elif ! files "$own" "$head" "$TMP/own"; then cls=unreadable; new="the own compare could not be read"
  fi
  if [ -z "$cls" ]; then
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      if r=$(cbe_reason "$p"); then new="$r"; break; fi
    done < "$TMP/own"
    if [ -z "$new" ]; then
      if TI_BATCH_SELECT=1 "$IMPACT" select --changed "$TMP/own" --out "$TMP/sel" 2>"$TMP/sel.why"; then
        r=$(sed -n 's/^impact: [0-9]* of [0-9]* suites (\(.*\))$/\1/p' "$TMP/sel.why" | tail -1)
        case "$r" in "full: "*) new="$r" ;; '') cls=unreadable; new="the selection had no impact line" ;; esac
      else
        cls=unreadable; new="the selection failed"
      fi
    fi
  fi
  if [ -z "$cls" ]; then
    tp=$(trigger "$OLD_REASON")
    inh=0; [ "$OLD_MODE" = full ] && [ -n "$tp" ] && ! grep -qxF -- "$tp" "$TMP/own" && inh=1
    if [ "$inh" = 1 ] && [ -n "$new" ]; then cls="inherited→full"
    elif [ "$inh" = 1 ]; then cls="inherited→selected"; new="selected (old trigger $tp is not in the own diff)"
    elif [ -n "$new" ]; then cls=own
    elif [ "$OLD_MODE" = full ] && [ -z "$tp" ]; then cls=full-other; new="${OLD_REASON#full: }"
    else cls=selected; new=selected
    fi
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$n" "${base:0:8}" "${own:0:8}" "$OLD_MODE" "$OLD_REASON" "$cls" "$new" "$SHARD_MIN" >> "$TMP/rows"
done < "$TMP/drafts.n"

[ -z "$OUTF" ] || cp "$TMP/rows" "$OUTF" || { echo "replay: cannot write $OUTF" >&2; exit 2; }
cat "$TMP/rows"
awk -F'\t' -v approx="$APPROX" '
  NR == 1 { next }
  { n++; c[$6]++ }
  $4 == "full" { oldfull++ }
  $6 ~ /^inherited/ { inh++ }
  $6 == "inherited→full" || $6 == "own" || $6 == "full-other" { still++; if ($3 == "-") stillnob++ }
  $6 == "inherited→selected" && $8 != "-" { ns += $8; nn++ }
  $4 == "batch-selected" && $8 != "-" { ss += $8; sn++ }
  function mean(s, k) { return k ? sprintf("%.1f", s / k) : "-" }
  END {
    printf "batches read: %d (unreadable %d)\n", n, c["unreadable"]
    printf "old full: %d\n", oldfull
    printf "inherited-trigger full: %d -> %d\n", inh, c["inherited→full"]
    printf "narrowed by the own diff: %d\n", c["inherited→selected"]
    printf "inherited-only mean shard min (old): %s over %d\n", mean(ns, nn), nn
    printf "batch-selected mean shard min (old, window): %s over %d\n", mean(ss, sn), sn
    printf "full fallback still fires: %d of %d (own base -: %d)\n", still, n, stillnob
    printf "selection step: %s\n", approx
  }' "$TMP/rows"
exit 0
