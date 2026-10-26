#!/bin/bash
# bin/context-signature.sh <project> [repo-or-worktree-dir] — capture WHICH rules
# and prompts a build actually ran under, as a comparable signature.
#
# Why (the operator, 2026-08-14): after the CLAUDE.md drift incident — three boxes had
# been building client software under a 2.5KB ruleset while hub had 12.4KB, and
# nobody could tell from a PR — a build has to carry its own context provenance.
# Two questions this answers that nothing else did:
#   1. Looking at a PR: what rules/prompts produced this diff?
#   2. Across boxes and over time: did the context drift between two builds?
#
# Two identifiers per input, deliberately:
#   - harness_commit  the cromford SHA, i.e. what the REPO says the rules are
#   - sha256          the hash of the file actually on disk, i.e. what was USED
# When those disagree the box is out of sync with its checkout, and `in_sync`
# goes false. That single boolean is the drift alarm the fleet was missing.
#
# usage: context-signature.sh <project> [dir]     -> JSON on stdout
set -uo pipefail
PROJECT="${1:?project}"
REPO="${2:-/root/repos/$PROJECT}"
HARNESS=/root/harness
CHECKOUT="${HARNESS_CHECKOUT:-/root/harness-checkout}"   # override for tests only

# "-" for a missing file, never empty: an empty field collapses the manifest's
# whitespace and the reader silently shifts sha into bytes.
sha_of() { [ -f "$1" ] && sha256sum "$1" 2>/dev/null | cut -d' ' -f1 || echo "-"; }
bytes_of() { [ -f "$1" ] && stat -c %s "$1" 2>/dev/null || echo 0; }
jstr() { printf '%s' "${1:-}" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

MACHINE_RULES=/root/.claude/CLAUDE.md
# The canon is the fleet rules head when the hub rendered one (BH-7971,
# bin/lib/rules-canon.sh), else the checkout's rules/CLAUDE.md: the same file
# sync-agent-rules.sh apply writes, so machine_rules_in_sync agrees with it.
# shellcheck source=bin/lib/rules-canon.sh
. "$(dirname "$0")/lib/rules-canon.sh" 2>/dev/null || rules_canon_path() { printf '%s\n' "$2/rules/CLAUDE.md"; }
CANON_RULES=$(rules_canon_path "$HARNESS" "$CHECKOUT")
LOCAL_RULES=/root/.claude/CLAUDE.local.md

HARNESS_COMMIT=$(git -C "$CHECKOUT" rev-parse --short HEAD 2>/dev/null || echo unknown)
# Was the CHECKOUT itself current with the repo? (2026-08-14) Read-only: uses the
# refs from the last fetch, never the network, so capturing a signature stays
# cheap. "unknown" when there is no origin ref — never optimistically "true".
CK_BRANCH=$(git -C "$CHECKOUT" rev-parse --abbrev-ref HEAD 2>/dev/null)
[ -n "$CK_BRANCH" ] && [ "$CK_BRANCH" != HEAD ] || CK_BRANCH=main
ORIGIN_COMMIT=$(git -C "$CHECKOUT" rev-parse --short "origin/$CK_BRANCH" 2>/dev/null || echo unknown)
if [ "$ORIGIN_COMMIT" = unknown ]; then
  CHECKOUT_FRESH='"unknown"'
elif [ "$ORIGIN_COMMIT" = "$(git -C "$CHECKOUT" rev-parse --short HEAD 2>/dev/null)" ]; then
  CHECKOUT_FRESH=true
else
  CHECKOUT_FRESH=false
fi
# How stale the freshness answer itself is: refs age between fetches.
FETCH_AGE_MIN=$(( ( $(date +%s) - $(stat -c %Y "$CHECKOUT/.git/FETCH_HEAD" 2>/dev/null || echo 0) ) / 60 ))

# Live bin can be ahead/behind its checkout (hot-deploys happen); say so.
# Compare only files the checkout owns — /root/harness/bin also accumulates
# .bak-* and __pycache__ that were never in the repo, and counting those as
# drift would pin this to false forever and make the signal worthless.
BIN_IN_SYNC=true
if [ -d "$CHECKOUT/bin" ]; then
  while IFS= read -r f; do
    cmp -s "$CHECKOUT/bin/$f" "$HARNESS/bin/$f" || { BIN_IN_SYNC=false; break; }
  done < <(cd "$CHECKOUT/bin" && find . -maxdepth 1 -type f -printf '%f\n' 2>/dev/null)
fi

MR_SHA=$(sha_of "$MACHINE_RULES")
# The canonical file plus any box-local appendix is what SHOULD be live.
RULES_IN_SYNC=false
if [ -f "$CANON_RULES" ]; then
  EXPECT=$(mktemp); cat "$CANON_RULES" > "$EXPECT"
  [ -f "$LOCAL_RULES" ] && { printf '\n\n<!-- box-specific, from %s -->\n\n' "$LOCAL_RULES" >> "$EXPECT"; cat "$LOCAL_RULES" >> "$EXPECT"; }
  cmp -s "$EXPECT" "$MACHINE_RULES" && RULES_IN_SYNC=true
  rm -f "$EXPECT"
fi

# Every input that shapes a build, in a fixed order so the digest is stable.
INPUTS=(
  "machine_rules:$MACHINE_RULES"
  "machine_rules_local:$LOCAL_RULES"
  "project_rules:$REPO/CLAUDE.md"
  "project_agents:$REPO/AGENTS.md"
  "board_prompt:$HARNESS/prompts/$PROJECT.md"
  "build_discipline:$HARNESS/prompts/build-discipline.md"
)

MANIFEST=$(mktemp)
for pair in "${INPUTS[@]}"; do
  name="${pair%%:*}"; path="${pair#*:}"
  printf '%s %s %s\n' "$name" "$(sha_of "$path")" "$(bytes_of "$path")" >> "$MANIFEST"
done
# The signature covers the CONTENT of every input plus the harness commit, so two
# builds sharing a signature genuinely ran under identical context.
SIGNATURE=$(printf '%s\n%s' "$HARNESS_COMMIT" "$(cat "$MANIFEST")" | sha256sum | cut -d' ' -f1)

{
  printf '{\n'
  printf '  "captured_at": "%s",\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  printf '  "host": "%s",\n' "$(jstr "$(hostname)")"
  printf '  "project": "%s",\n' "$(jstr "$PROJECT")"
  printf '  "signature": "%s",\n' "$SIGNATURE"
  printf '  "signature_short": "%s",\n' "${SIGNATURE:0:12}"
  printf '  "harness_commit": "%s",\n' "$(jstr "$HARNESS_COMMIT")"
  printf '  "origin_commit": "%s",\n' "$(jstr "$ORIGIN_COMMIT")"
  printf '  "checkout_fresh": %s,\n' "$CHECKOUT_FRESH"
  printf '  "origin_refs_age_min": %s,\n' "${FETCH_AGE_MIN:-0}"
  printf '  "harness_bin_in_sync": %s,\n' "$BIN_IN_SYNC"
  printf '  "machine_rules_in_sync": %s,\n' "$RULES_IN_SYNC"
  printf '  "inputs": {\n'
  first=1
  while read -r name sha bytes; do
    [ $first -eq 1 ] || printf ',\n'; first=0
    printf '    "%s": { "sha256": "%s", "bytes": %s }' "$name" "$sha" "${bytes:-0}"
  done < "$MANIFEST"
  printf '\n  }\n}\n'
}
rm -f "$MANIFEST"
