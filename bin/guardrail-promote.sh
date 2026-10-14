#!/bin/bash
# bin/guardrail-promote.sh <checks-dir>
#
# The mechanizable lane of the rule miner (Wave A). The prose lane turns a
# recurring incident into a build-discipline bullet; this one turns it into a
# check that runs in the TARGET repo's CI. One PR per drafted check, on the
# project's own repo, never merged.
#
# Input: a directory of drafted checks, one subdirectory per check, written by
# the mining session:
#   <slug>/TARGET       one line, owner/repo — where the check belongs
#   <slug>/ci-step.yml  the CI step, including the escape hatch
#   <slug>/rule.yml | check.sh | eslint.json   the check itself
#   <slug>/README.md    what it catches, applicability, known false positives
#
# WHY A SEPARATE SCRIPT. This lane pushes branches to CLIENT repos on the say-so
# of an LLM draft, so its refusals are the load-bearing part and they have to be
# testable without a network: tests/guardrail-promote-test.sh drives it with a
# fake gh on PATH and asserts the silence. Leaving it inline in rule-miner.sh
# would have made that untestable, and an untested refusal is a refusal you find
# out about from a client.
#
# REFUSALS (each alerts and continues to the next check — one bad draft never
# costs a good sibling its PR):
#   * ANY draft file that is not a regular non-symlink file. `cp`/`cat`/`sed`
#     all dereference, so a rule.yml symlinked at a secrets file got the
#     target's CONTENTS committed, pushed, and printed into a PR body on a
#     client repo. Reproduced live in review; checked BEFORE anything is read.
#   * no TARGET, or a TARGET that is not owner/repo
#   * TARGET is the harness repo itself — guardrails go to project repos; the
#     prose lane is the only thing that ever writes to the harness
#   * TARGET not listed in fleet.conf. "owner/repo"-shaped is not "ours", and
#     an invented TARGET would otherwise be cloned and pushed to.
#   * no check file
#   * ci-step.yml missing the `skip-guardrail` label condition, or missing
#     GUARDRAIL_JUSTIFICATION. A guardrail with no way out gets deleted the
#     first time it is wrong; a hatch that is a bare label makes the label the
#     whole gate. Both halves or no PR.
#   * ci-step.yml wiring GUARDRAIL_JUSTIFICATION to the raw PR body — that
#     makes any body a justification, and it is the line drafts copy.
#
# VOLUME: MAX_PROMOTE (default 3) PRs per run. Without it one misfiring session
# opened 25 PRs on a single client repo. Hitting the cap alerts; it never stops
# silently.
#
# NEVER MERGES, and never can: it calls `gh pr create` and nothing else.
# Fail-open throughout, like every lane in this repo: exit 0 always.
set -uo pipefail
HARNESS="${HARNESS:-/root/harness}"
# BH-4080: HARNESS_REPO's default lives in the deployment defaults home.
# shellcheck source=bin/lib/deployment.sh
. "${HARNESS_DEPLOYMENT_FILE-$(dirname "${BASH_SOURCE[0]}")/lib/deployment.sh}" || exit 0
# Volume cap. A drafting session that misfires can emit dozens of check dirs,
# and without this the loop below cheerfully opened 25 PRs on one client repo in
# one run. Three is a review queue; twenty-five is an incident.
MAX_PROMOTE="${MAX_PROMOTE:-3}"
CHECKS="${1:-}"
SELF="$(cd "$(dirname "$0")" && pwd)" || exit 0
# The App token for the repo each draft targets; unarmed box = no arm, as today.
# shellcheck source=bin/lib/gh-app-auth.sh
[ -r "$SELF/lib/gh-app-auth.sh" ] && . "$SELF/lib/gh-app-auth.sh" 2>/dev/null
STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
LOG="$HARNESS/logs/rule-miner.log"
ALERTS="$HARNESS/logs/ALERTS.log"
mkdir -p "$HARNESS/logs" 2>/dev/null || exit 0
[ -n "$CHECKS" ] && [ -d "$CHECKS" ] || exit 0
DATE=$(date -u +%Y%m%d)

refuse() { # refuse <slug> <reason>
  echo "$(STAMP) [guardrail-promote] refused drafted check '$1': $2" >> "$ALERTS"
  echo "$(STAMP) [guardrail-promote] refused '$1': $2" >> "$LOG"
}

# A draft file must be a REGULAR file, never a symlink. `cp` dereferences, and
# so do `cat`/`sed` — so a drafted rule.yml symlinked at ~/.ssh/id_rsa or an
# env file gets the TARGET'S CONTENTS committed, pushed, and printed into a PR
# body on a client repo. This was reproduced live, not theorised. The drafts
# are LLM-written and hit disk before any human reads them, so "a draft would
# not do that" is not a control. Check before reading, not before copying.
regular_file() { [ -f "$1" ] && [ ! -L "$1" ]; }

# TARGET allowlist. "owner/repo"-shaped is not the same as "ours": an invented
# TARGET would have been cloned and had a branch pushed to it. Only repos this
# fleet actually declares are eligible.
FLEET_REPOS=$("$SELF/fleet-conf.sh" --projects 2>/dev/null | while IFS= read -r P; do
  [ -n "$P" ] && "$SELF/fleet-conf.sh" "$P" repo 2>/dev/null
done)
if [ -z "$FLEET_REPOS" ]; then
  # Deliberately fail CLOSED, against this repo's usual fail-open house style.
  # Everywhere else fail-open costs a missed observation; here it would mean
  # pushing branches to unvalidated repos because a config read failed.
  echo "$(STAMP) [guardrail-promote] cannot read fleet.conf repo slugs — refusing ALL promotions this run (fail-closed: this gate protects client repos)" >> "$ALERTS"
  exit 0
fi

PROMOTED=0
find "$CHECKS" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort | while IFS= read -r D; do
  SLUG=$(basename "$D")
  if [ "$PROMOTED" -ge "$MAX_PROMOTE" ]; then
    echo "$(STAMP) [guardrail-promote] MAX_PROMOTE=$MAX_PROMOTE reached — stopping with drafts left in $CHECKS (raise MAX_PROMOTE deliberately, or look at why one session drafted this many checks)" >> "$ALERTS"
    break
  fi
  regular_file "$D/TARGET" || { refuse "$SLUG" "TARGET is missing, a symlink, or not a regular file"; continue; }
  TARGET=$(head -1 "$D/TARGET" 2>/dev/null | tr -d '[:space:]')
  case "$TARGET" in
    */*) ;;
    *) refuse "$SLUG" "no usable TARGET file (want one line: owner/repo)"; continue ;;
  esac
  if [ "$TARGET" = "$HARNESS_REPO" ]; then
    refuse "$SLUG" "TARGET is the harness repo — guardrails ship to project repos, never here"
    continue
  fi
  if ! grep -qxF "$TARGET" <<<"$FLEET_REPOS"; then
    refuse "$SLUG" "TARGET '$TARGET' is not in fleet.conf — not a fleet repo, refusing to clone or push to it"
    continue
  fi
  CHECKFILE=""
  for F in rule.yml rule.yaml check.sh eslint.json eslintrc-fragment.json; do
    regular_file "$D/$F" && { CHECKFILE="$F"; break; }
  done
  [ -n "$CHECKFILE" ] || { refuse "$SLUG" "no check file (rule.yml / check.sh / eslint.json) as a regular non-symlink file"; continue; }
  # README.md and WHY.md are piped into the PR BODY, so they exfiltrate just as
  # well as a committed file. Optional, but if present they must be real files.
  BADDOC=""
  for F in README.md WHY.md; do
    [ -e "$D/$F" ] && ! regular_file "$D/$F" && BADDOC="$F"
  done
  [ -z "$BADDOC" ] || { refuse "$SLUG" "$BADDOC is a symlink — it would be read straight into the PR body"; continue; }
  STEP="$D/ci-step.yml"
  regular_file "$STEP" || { refuse "$SLUG" "ci-step.yml is missing, a symlink, or not a regular file"; continue; }
  if [ ! -s "$STEP" ] || ! grep -q 'skip-guardrail' "$STEP"; then
    refuse "$SLUG" "ci-step.yml missing the skip-guardrail escape hatch"
    continue
  fi
  if ! grep -q 'GUARDRAIL_JUSTIFICATION' "$STEP"; then
    refuse "$SLUG" "escape hatch has no mandatory justification — a bare label is not a hatch"
    continue
  fi
  # Wiring the justification to the raw PR body makes ANY body a justification —
  # including 25 spaces. It is also the pattern drafts copy from a sample, so it
  # propagates. The hatch reads a dedicated `Guardrail-Justification:` line.
  if grep -qE 'GUARDRAIL_JUSTIFICATION.*github\.event\.pull_request\.body' "$STEP"; then
    refuse "$SLUG" "escape hatch wires GUARDRAIL_JUSTIFICATION to the raw PR body — any body would satisfy it; use a dedicated 'Guardrail-Justification:' line"
    continue
  fi

  # One check dir is one target repo: the repo boundary, after $TARGET is validated.
  command -v gh_auth_for >/dev/null 2>&1 && gh_auth_for "$TARGET" || true
  WT=$(mktemp -d "/tmp/guardrail-$SLUG-XXXXXX") || { refuse "$SLUG" "no workspace"; continue; }
  if ! gh repo clone "$TARGET" "$WT" -- -q >/dev/null 2>&1; then
    refuse "$SLUG" "clone of $TARGET failed (gh auth or network)"
    rm -rf "$WT"; continue
  fi
  BRANCH="guardrails/$SLUG-$DATE"
  BODY="$WT/.guardrail-pr-body.md"
  {
    echo "Drafted by the harness rule miner (\`bin/rule-miner.sh\` → \`bin/guardrail-promote.sh\`) from a **recurring review-finding family**: the same review comment was written repeatedly across recent builds, and a recurring review comment is a bug in the guardrails rather than a bug in that week's build."
    echo
    echo "**Not merged, and the miner cannot merge it.** For a human to adopt, adjust, or reject."
    if [ -s "$D/WHY.md" ]; then
      echo
      echo "## Why this recurred"
      echo
      cat "$D/WHY.md"
    fi
    echo
    echo "## The check"
    echo
    sed 's/^/> /' "$D/README.md" 2>/dev/null
    echo
    echo "## Before merging"
    echo
    echo "1. Run it against \`main\` as it stands and count existing violations. A check that lands red gets disabled within a week — fix them in this PR, or narrow the exclusions with a written reason per exclusion."
    echo "2. Seed one violation, show CI failing, revert. A green CI on a clean tree proves the step ran, not that it can fail."
    echo "3. Confirm the escape hatch: \`skip-guardrail\` label **plus** a written justification. The label alone must not skip it."
    echo
    echo "🤖 Generated with [Claude Code](https://claude.com/claude-code)"
  } > "$BODY"

  if (cd "$WT" \
      && git checkout -qb "$BRANCH" \
      && mkdir -p ".guardrails/$SLUG" \
      && cp "$D/$CHECKFILE" "$D/ci-step.yml" ".guardrails/$SLUG/" \
      && { [ -f "$D/README.md" ] && cp "$D/README.md" ".guardrails/$SLUG/" || true; } \
      && git add ".guardrails/$SLUG" \
      && git -c user.name="rule-miner" -c user.email="harness@box" \
           commit -qm "guardrails: add $SLUG check (drafted from a recurring review finding)" \
      && git push -q origin "$BRANCH") >/dev/null 2>&1; then
    # >>> pr trailers (BH-3987)
    [ -r "${HARNESS:-}/bin/lib/pr-trailers.sh" ] && . "$HARNESS/bin/lib/pr-trailers.sh"
    if command -v pr_trailers_apply >/dev/null 2>&1; then
      pr_trailers_apply "$BODY" lane:guardrail-promote none \
        || echo "$(STAMP) [guardrail-promote] pr trailers: could not write $BODY — PR opened without trailers" >> "$LOG"
    fi
    URL=$(gh pr create -R "$TARGET" -B main -H "$BRANCH" \
      -t "guardrails: adopt the $SLUG check" --body-file "$BODY" 2>/dev/null)
    # <<< pr trailers
    if [ -n "$URL" ]; then
      PROMOTED=$((PROMOTED + 1))
      # Record WHICH family this PR addressed. rule-miner marks seen.txt from
      # this list, so a family whose check never shipped is re-mined next week
      # instead of being silently written off.
      FAM=$(grep -m1 -E '^FAMILY:' "$D/WHY.md" 2>/dev/null | awk '{print $2}' | tr -cd 'a-f0-9')
      [ -n "$FAM" ] && echo "findings:$FAM" >> "$CHECKS/.promoted-families"
      echo "$(STAMP) [guardrail-promote] $SLUG -> $TARGET: $URL" >> "$LOG"
      echo "$URL"
    else
      refuse "$SLUG" "branch pushed to $TARGET but gh pr create failed — open it by hand from $BRANCH"
    fi
  else
    refuse "$SLUG" "could not commit/push $BRANCH to $TARGET"
  fi
  # End of this repo's section — inside the body, because the `find | … | while`
  # pipeline is a subshell and a reset after `done` would never see the arm.
  command -v gh_auth_reset >/dev/null 2>&1 && gh_auth_reset
  rm -rf "$WT"
done
exit 0
