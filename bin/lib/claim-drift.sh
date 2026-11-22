#!/bin/bash
# bin/lib/claim-drift.sh — BH-9440 C4: A DIFF THAT LEFT ITS DECLARED LIST IS
# RE-CLAIMED AND RE-GATED BEFORE THE PR OPENS. Sourced, never executed.
#
# The plan stage posts its file list once (bin/lib/rb/plan.sh, `FILE_CLAIM`):
# the box-local shadow copy and the build's job_claims row (fclaim_put). A build whose real diff then changes a file that list did not
# name holds that file with no claim: a sibling planner on any box sees nothing
# there, and the overlap guard never compared it with the open PRs.
#
# claim_drift_check <build-dir> <base-ref>
#   Run in the build worktree, before the PR create (bin/lib/rb/pr.sh).
#   The claim list is the one the plan stage posted: touch-files.txt when
#   touch-source is `declared`, else claim-files.txt, else planned-files.txt.
#   drift = `git diff --name-only <base>...HEAD` minus that list (a listed
#   directory covers the files under it). With no drift: one pipeline.log line
#   `CLAIM_DRIFT n=0`, nothing posted. With drift:
#     1. the union goes to <build>/claim-files.txt (written first: a DB
#        failure never loses it). The box-local shadow state/claims/<p>/<K> is
#        not written here: job_claims is its authority (BH-5002), and a new
#        script must not grow a writer of a `rows` path (bin/state-paths-guard.sh);
#     2. fclaim_put posts the union (this also renews the claim's TTL,
#        FILE_CLAIM_TTL_S); db=ok|failed|skipped is logged, as plan.sh logs it;
#     3. bin/overlap-guard.sh <p> <K> judges the UNION (OVERLAP_CAND_FILE)
#        against the running builds and the open PRs again;
#     4. pipeline.log gets `CLAIM_DRIFT n=<n> files=<a,b,c> db=<s> guard=<line>`
#        and <build>/claim-drift.md gets a `## Claim drift` PR-body section.
#   A guard DEFER does not stop the PR: the diff is already written and paid
#   for, and the merge queue and the conductor handle the overlap. The section
#   says so. rc 0 always; every missing input fails open with its log line.
# Reads: HARNESS PROJECT KEY JOBS_URL JOB_ID (and _jobs_req / fclaim_put when
# the caller has sourced bin/jobs-client.sh).

claim_drift_check() {
  local b="${1:-}" base="${2:-}" claim d names drift n files db=skipped g="skipped" log
  [ -n "$b" ] && [ -d "$b" ] || return 0
  log="$b/pipeline.log"
  _cd_say() { echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') [${PROJECT:-?}/${KEY:-?}] $*" >> "$log" 2>/dev/null || :; }
  rm -f "$b/claim-drift.md" 2>/dev/null
  if [ "$(cat "$b/touch-source" 2>/dev/null)" = declared ] && [ -s "$b/touch-files.txt" ]; then claim="$b/touch-files.txt"
  elif [ -s "$b/claim-files.txt" ]; then claim="$b/claim-files.txt"
  else claim="$b/planned-files.txt"; fi
  if ! [ -s "$claim" ]; then _cd_say "CLAIM_DRIFT skipped: no claim list"; return 0; fi
  [ -n "$base" ] || { _cd_say "CLAIM_DRIFT skipped: no base ref"; return 0; }
  names=$(git diff --name-only "$base...HEAD" 2>/dev/null) || { _cd_say "CLAIM_DRIFT skipped: git diff $base...HEAD did not answer"; return 0; }
  # A path is covered when the list names it, or names a directory above it.
  drift=$(printf '%s\n' "$names" | awk -v cf="$claim" '
    BEGIN { while ((getline l < cf) > 0) { sub(/^\.\//, "", l); sub(/\/+$/, "", l); if (l != "" && l !~ /^SOURCE:/) c[l] = 1 } }
    $0 == "" { next }
    { p = $0; if (p in c) next; q = p
      while ((i = match(q, /\/[^\/]*$/)) > 0) { q = substr(q, 1, i - 1); if (q in c) next }
      print p }' | sort -u)
  n=$(printf '%s\n' "$drift" | grep -c .)
  if [ "${n:-0}" = 0 ]; then _cd_say "CLAIM_DRIFT n=0 (the diff stays inside $(basename "$claim"))"; return 0; fi
  files=$(head -n 5 <<<"$drift" | paste -sd, -)
  [ "$n" -gt 5 ] && files="$files,+$((n - 5))"
  # 1. the union, locally first
  { grep -v '^SOURCE:' "$claim"; printf '%s\n' "$drift"; } | sed '/^[[:space:]]*$/d' | awk '!s[$0]++' > "$b/claim-files.txt.new" \
    && mv -f "$b/claim-files.txt.new" "$b/claim-files.txt"
  # 2. the job_claims row (renews the TTL)
  if [ -n "${HARNESS:-}" ] && ! command -v fclaim_put >/dev/null 2>&1; then
    # shellcheck source=bin/lib/file-claims.sh
    [ -r "$HARNESS/bin/lib/file-claims.sh" ] && . "$HARNESS/bin/lib/file-claims.sh" 2>/dev/null
  fi
  if [ -n "${JOBS_URL:-}" ] && [ -n "${JOB_ID:-}" ] && command -v fclaim_put >/dev/null 2>&1; then
    if fclaim_put "$b/claim-files.txt" >/dev/null 2>&1; then db=ok; else db=failed; fi
  fi
  # 3. the guard, on the union
  if [ -n "${HARNESS:-}" ] && [ -x "$HARNESS/bin/overlap-guard.sh" ] && [ -n "${PROJECT:-}" ] && [ -n "${KEY:-}" ]; then
    g=$(HARNESS="$HARNESS" OVERLAP_CAND_FILE="$b/claim-files.txt" "$HARNESS/bin/overlap-guard.sh" "$PROJECT" "$KEY" 2>/dev/null | head -n 1)
    [ -n "$g" ] || g="no answer"
  fi
  # 4. the record
  _cd_say "CLAIM_DRIFT n=$n files=$files db=$db guard=$g"
  {
    printf '## Claim drift\n\n'
    printf 'This diff changes %s file(s) that the plan did not declare: %s.\n' "$n" "$(head -n 10 <<<"$drift" | sed 's/.*/`&`/' | paste -sd, - | sed 's/,/, /g')"
    printf 'The build added them to its file claim before it opened this PR (job_claims: %s).\n' "$db"
    printf 'The overlap guard judged the new list again: `%s`.\n' "$g"
    case "$g" in
      DEFER*) printf 'The guard found an owner of one of these files. The PR opens anyway: the diff is already written, and the merge queue and the conductor handle the overlap.\n' ;;
    esac
  } > "$b/claim-drift.md" 2>/dev/null || rm -f "$b/claim-drift.md"
  return 0
}
