#!/bin/bash
# guardrails/lib/batch-hatch.sh — the escape hatch on a Mergify batch draft PR
# (BH-9965). Sourced by lib/escape-hatch.sh only when the run is a batch draft;
# never sourced by a check directly.
#
# Mergify tests a batch on its own draft PR (`mergify/merge-queue/*`). The draft
# carries neither the source PRs' labels nor their bodies, so the ordinary hatch
# would fail every batch that holds a hatched PR. Here the hatch reads each
# SOURCE PR instead:
#
#   1. the source PR numbers come from the draft body's `Metadata for CI tooling`
#      YAML block (`pull_requests:` / `  - number: <n>`), GUARDRAIL_DRAFT_BODY;
#   2. each source PR's labels and body are read from the GitHub REST API, and the
#      hatch decision is the ordinary guardrail_escape_hatch run on them, so
#      "label, no justification" prints the same message as on the PR itself;
#   3. only when a source PR is hatched are the file lists read, and the exempt
#      set is the files hatched PRs changed MINUS the files any non-hatched PR
#      changed. A file both touched is checked.
#
# It ALWAYS returns 1 (run the check). On success GUARDRAIL_EXEMPT holds the
# exempt paths. Every failure (no source PR number, no GITHUB_REPOSITORY, an API
# error, no jq, an incomplete file list of a non-hatched PR) prints one line and
# leaves GUARDRAIL_EXEMPT empty, so the check runs on every file as today.
#
# The GitHub seam: every call is "${GUARDRAIL_GH:-gh}" api ... — tests point
# GUARDRAIL_GH at a stub. Calls: 1 per source PR, plus 1 per source PR (its
# file list) only when at least one is hatched.

# guardrail_batch_prs <draft body>: the source PR numbers, one per line. Only a
# `- number: <digits>` item inside a top-level `pull_requests:` block counts;
# the block ends at the next top-level key or fence. CR is stripped.
guardrail_batch_prs() {
  printf '%s\n' "${1:-}" | tr -d '\r' | awk '
    /^pull_requests:[[:space:]]*$/ { inblk = 1; next }
    inblk && /^[^[:space:]-]/ { inblk = 0 }
    inblk && /^---|^\.\.\./ { inblk = 0 }
    inblk && /^[[:space:]]*-[[:space:]]+number:[[:space:]]*[0-9]+[[:space:]]*$/ {
      s = $0; sub(/^[[:space:]]*-[[:space:]]+number:[[:space:]]*/, "", s); sub(/[[:space:]]+$/, "", s)
      if (!(s in seen)) { seen[s] = 1; print s }
    }
  '
}

_guardrail_batch_fail() { # _guardrail_batch_fail <check> <why>
  echo "GUARDRAIL $1: batch draft: could not read source PR(s) ($2); no file is exempt."
  GUARDRAIL_EXEMPT=""
  return 1
}

_guardrail_batch_hatch() {
  local check="${1:-guardrail}" gh="${GUARDRAIL_GH:-gh}" repo="${GITHUB_REPOSITORY:-}"
  local prs n json labels body out rc reason count fetched list
  local hatched="" plain="" summary="" hfiles="" pfiles=""
  GUARDRAIL_EXEMPT=""
  command -v jq >/dev/null 2>&1 || { _guardrail_batch_fail "$check" "jq is not installed"; return 1; }
  [ -n "$repo" ] || { _guardrail_batch_fail "$check" "GITHUB_REPOSITORY is not set"; return 1; }
  case "$repo" in
    */*/*|*[!A-Za-z0-9._/-]*|/*|*/) _guardrail_batch_fail "$check" "GITHUB_REPOSITORY is not owner/repo"; return 1 ;;
  esac
  prs=$(guardrail_batch_prs "${GUARDRAIL_DRAFT_BODY:-}")
  [ -n "$prs" ] || { _guardrail_batch_fail "$check" "no source PR number in the draft body"; return 1; }

  # One read per source PR: labels, body, changed_files.
  local -A changed=()
  while IFS= read -r n; do
    json=$("$gh" api "repos/$repo/pulls/$n" 2>/dev/null) \
      && labels=$(jq -r '[.labels[]?.name] | join(",")' <<<"$json" 2>/dev/null) \
      && body=$(jq -r '.body // ""' <<<"$json" 2>/dev/null) \
      && count=$(jq -r '.changed_files // -1' <<<"$json" 2>/dev/null) \
      || { _guardrail_batch_fail "$check" "could not read source PR #$n"; return 1; }
    changed[$n]=$count
    # The ordinary hatch on the source PR's own label and body. GUARDRAIL_HEAD_REF
    # is unset in the subshell, so this cannot recurse into batch mode.
    out=$(unset GUARDRAIL_HEAD_REF GUARDRAIL_PR_AUTHOR
          PR_LABELS="$labels" GUARDRAIL_JUSTIFICATION="$body" guardrail_escape_hatch "$check"); rc=$?
    # A refusal (label, no usable justification) prints the ordinary message
    # under the source PR's number. A hatch is NOT printed as "SKIPPED": the
    # check still runs, and the summary line below names the reason.
    if [ "$rc" -ne 0 ] && [ -n "$out" ]; then
      echo "GUARDRAIL $check: batch source PR #$n:"
      printf '%s\n' "$out"
    fi
    if [ "$rc" -eq 0 ]; then
      hatched="$hatched $n"
      reason=$(printf '%s\n' "$out" | sed -n 's/^  Justification: //p' | head -1)
      summary="${summary:+$summary, }#$n hatched (Justification: $reason)"
    else
      plain="$plain $n"
    fi
  done <<< "$prs"

  if [ -z "$hatched" ]; then
    echo "GUARDRAIL $check: batch draft: no source PR is hatched; no file is exempt."
    return 1
  fi

  # File lists, only now that a hatch exists. `--paginate` prints one JSON
  # array per page; jq reads the stream. A rename's old name counts as changed.
  for n in $hatched $plain; do
    json=$("$gh" api --paginate "repos/$repo/pulls/$n/files" 2>/dev/null) \
      && list=$(jq -r '.[] | .filename, (.previous_filename // empty)' <<<"$json" 2>/dev/null) \
      && fetched=$(jq -s 'map(length) | add // 0' <<<"$json" 2>/dev/null) \
      || { _guardrail_batch_fail "$check" "could not read the file list of #$n"; return 1; }
    case " $plain " in
      *" $n "*)
        # A non-hatched PR's list must be complete, or a file it changed could
        # be exempted by a hatched PR that changed it too.
        if [ "${changed[$n]}" -lt 0 ] || [ "$fetched" -lt "${changed[$n]}" ]; then
          _guardrail_batch_fail "$check" "file list of #$n is incomplete: $fetched of ${changed[$n]}"; return 1
        fi
        pfiles="$pfiles$list"$'\n' ;;
      # A hatched PR's incomplete list exempts only what was fetched.
      *) hfiles="$hfiles$list"$'\n' ;;
    esac
  done

  GUARDRAIL_EXEMPT=$(LC_ALL=C comm -23 <(printf '%s' "$hfiles" | grep -v '^$' | LC_ALL=C sort -u) \
                              <(printf '%s' "$pfiles" | grep -v '^$' | LC_ALL=C sort -u))
  local k=0
  [ -n "$GUARDRAIL_EXEMPT" ] && k=$(printf '%s\n' "$GUARDRAIL_EXEMPT" | grep -c .)
  echo "GUARDRAIL $check: batch draft: $summary; $k file(s) exempt."
  return 1
}
