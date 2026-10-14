#!/bin/bash
# GitHub identity (BH-1651): no raw gh call left; its one issue read goes through
# bin/lib/gh-rest.sh, which arms nothing, so it runs on whatever token the
# environment already carries, exactly as the raw call it replaced did.
# bin/planned-files-cheap.sh <project> <KEY>
#   writes plans/<project>-<KEY>/planned-files.txt, first line `SOURCE: <tier>`.
#   exit 0 on every path that is not a usage error. Silent when there is
#   nothing to say.
#
# WHAT THIS IS FOR (BH-499). bin/dep-verify.sh cannot answer anything about a
# child without the child's planned-files list: no list, no file half, so the
# verdict is UNKNOWN and every caller obeys UNKNOWN exactly like HARD. That list
# used to come from the speculative pre-plan lane — a full frontier-model plan
# at $2-6 a ticket, switched off on 2026-09-16 (flags/preplan-speculative-off)
# after 34 of 52 plans in three hours went stale against a moving main. Turning
# it off took the dependency evidence with it, and the wave went straight back
# to being as narrow as its hand-typed `Blocked-by:` graph.
#
# The house rule is deterministic-before-LLM, and most of that evidence never
# needed a model at all: a ticket body that says "add the helper in
# `src/lib/rollup.ts`" has already named the file. So three tiers, cheapest
# first, and the expensive one only runs when the other two found nothing:
#
#   1. ticket-body            every repo-relative path token in the issue body,
#                             filtered to the ones that exist in the checkout or
#                             sit under a directory that does. Free.
#   2. ticket-body+codegraph  when the repo carries a .codegraph/ index, each
#                             named file's DIRECT importers, one hop. Free.
#   3. model-floor            one call on the cheapest Claude-family model the
#                             price catalog carries, capped at one per ticket
#                             per 6h. Cents.
#
# THE TIER IS PART OF THE ANSWER, which is why it is written into the file
# rather than inferred. bin/dep-verify.sh treats tiers 1 and 2 as evidence
# strong enough to stand in for a missing `DEPENDS:` line, and tier 3 as good
# enough to say HARD on an overlap but never SOFT on a disjoint: a model
# guessing paths out of a body that named none is the weakest thing in the
# system, and a wrong SOFT is the one expensive outcome in the whole design.
#
# DEDUP BEFORE SPEND (the standing metered-API rule). The marker that burns the
# 6h window is written BEFORE the call, not after, and it is written on EVERY
# exit from the call — success, failure, and the third outcome that costs the
# most when it is missed: a call that succeeded and returned nothing. A guard
# that only runs on the success path leaves a ticket re-billing on every tick,
# which is how $1,678 of transcription became ~99% waste in five weeks.
#
# A DIRECTORY WITH A REAL PLAN IS LEFT ALONE. plans/<project>-<KEY>/ is the
# pre-plan's directory; if plan.md is in it, a planner has read the actual code
# and its list is better evidence than anything here. Overwriting it would
# downgrade a full pre-plan to a body scrape, silently.
#
# Kill flag: PLANNED_FILES_CHEAP=0 in env/global.env, or the settings row
# switch.planned-files-cheap-off.<box> or switch.planned-files-cheap-off
# (1 = off), read by lane_switch (bin/lib/lane-switch.sh);
# flags/planned-files-cheap-off decides only when neither row exists. Either one
# makes this write nothing at all.
#
# Overrides, all of them because the tests drive them:
#   PLANNED_FILES_BODY_FILE   the issue body the caller already has
#                             (bin/preplan-candidates.sh does — its `gh issue
#                             list` already fetched every body, so the whole
#                             tier-1 pass costs it zero extra requests)
#   PLANNED_FILES_REPO        the checkout paths are checked against
#   PLANNED_FILES_MODEL       the floor model, instead of the catalog's cheapest
#   PLANNED_FILES_MODEL_TTL   the cap window in seconds (default 21600 = 6h)
#   CODEGRAPH_BIN             the codegraph CLI
#   PLANNED_FILES_META_FILE   the ticket's {title,labels} JSON, in the shape
#                             bin/kind-gate.sh reads (bin/preplan-candidates.sh
#                             writes it from the `gh issue list` it already made)
#   PLANNED_FILES_KIND        the ticket KIND outright, skipping kind-gate
#   PLANNED_FILES_FREE_ONLY   1 = tiers 1-2 only, never the tier-3 model call
#                             (the pre-plan small-skip, bin/lib/preplan-lib.sh)
set -uo pipefail
# BH-2303: every model call this lane makes names the lane, so its cost rows
# carry lane_id and its LLM_* knobs (on/off, runners, daily cap) bind it alone.
export AGENT_CALL_LANE=preplan-tick
PROJECT="${1:?usage: planned-files-cheap.sh <project> <KEY>}"
KEY="${2:?usage: planned-files-cheap.sh <project> <KEY>}"
HARNESS="${HARNESS:-/root/harness}"
HERE="$(cd "$(dirname "$0")" && pwd)"
LOG="$HARNESS/logs/preplan.log"
say() { printf '%s [%s/%s] planned-files-cheap: %s\n' \
        "$(date -u '+%Y-%m-%d %H:%M:%SZ')" "$PROJECT" "$KEY" "$1" >> "$LOG" 2>/dev/null || true; }

# shellcheck source=bin/lib/preplan-lib.sh
[ -r "$HERE/lib/preplan-lib.sh" ] && . "$HERE/lib/preplan-lib.sh" 2>/dev/null
command -v _preplan_env >/dev/null 2>&1 || exit 0

# shellcheck source=lib/lane-switch.sh
. "$HERE/lib/lane-switch.sh" || exit 1
lane_switch planned-files-cheap-off && exit 0
case "$(_preplan_env "$HARNESS" PLANNED_FILES_CHEAP 1)" in 0|no|off|false) exit 0 ;; esac

PLANDIR="$HARNESS/plans/$PROJECT-$KEY"
[ -s "$PLANDIR/plan.md" ] && exit 0
REPO="${PLANNED_FILES_REPO:-${REPOS_ROOT:-/root/repos}/$PROJECT}"

TD=$(mktemp -d) || exit 0
trap 'rm -rf "$TD"' EXIT

# ---- the body --------------------------------------------------------------
BODY="$TD/body"
if [ -n "${PLANNED_FILES_BODY_FILE:-}" ]; then
  [ -r "$PLANNED_FILES_BODY_FILE" ] || { say "handed-in body is unreadable — nothing written"; exit 0; }
  cp "$PLANNED_FILES_BODY_FILE" "$BODY" 2>/dev/null || exit 0
else
  # shellcheck source=bin/lib/dep-verify-lib.sh
  [ -r "$HERE/lib/dep-verify-lib.sh" ] && . "$HERE/lib/dep-verify-lib.sh" 2>/dev/null
  command -v dep_repo_for >/dev/null 2>&1 || exit 0
  SLUG=$(dep_repo_for "$HARNESS" "$PROJECT" 2>/dev/null) || SLUG=""
  # In-app boards have no issue bodies to read here and no dep-verify consumer
  # for the list either, so this is a no-op there rather than a second board
  # client that could disagree with bin/preplan-candidates.sh's.
  [ -n "$SLUG" ] || { say "no GitHub-Issues repo — nothing to extract a body from"; exit 0; }
  N="${KEY##*-}"
  case "$N" in ''|*[!0-9]*) say "KEY has no issue number — nothing written"; exit 0 ;; esac
  # BH-1651: REST, and a read that did not answer is never an "empty body".
  for _P in "$HERE/lib/gh-rest.sh" "$HARNESS/bin/lib/gh-rest.sh"; do
    # shellcheck source=bin/lib/gh-rest.sh
    [ -r "$_P" ] && { . "$_P"; break; }
  done
  command -v gh_rest >/dev/null 2>&1 || { say "no gh-rest library — nothing written"; exit 0; }
  rc=0
  gh_rest GET "repos/$SLUG/issues/$N" > "$TD/issue.json" || rc=$?
  if [ "$rc" != 0 ]; then say "could not read ticket #$N (HTTP $GH_REST_STATUS) — nothing written"; exit 0; fi
  jq -r '.body // ""' "$TD/issue.json" > "$BODY" 2>/dev/null \
    || { say "could not parse ticket #$N — nothing written"; exit 0; }
fi
[ -s "$BODY" ] || { say "empty ticket body — nothing written"; exit 0; }

# ---- the extractor ---------------------------------------------------------
# DELIBERATELY bin/planned-files.sh's, transcribed: the same extension list, the
# same top-level prefixes, the same bare-directory scopes and the same
# fewer-than-three-segments prune. Two spellings of "the files this ticket owns"
# is a child whose list means something different from its parent's, compared
# against each other by bin/dep-verify.sh as though it did not. The project's
# own roots come from the same row (bin/lib/claim-roots.sh), spelled the same way.
EXTRA=""
# shellcheck source=bin/lib/claim-roots.sh
[ -r "$HERE/lib/claim-roots.sh" ] && . "$HERE/lib/claim-roots.sh" 2>/dev/null \
  && EXTRA=$(claim_roots_list "$HERE/../catalog" "$(claim_roots_project "$HERE/../catalog" "$PROJECT")" \
             | sed 's/\./\\./g' | paste -sd'|')
extract() {
  grep -oE '[][A-Za-z0-9_@()/.-]+\.(ts|tsx|js|jsx|mjs|sql|prisma|css|scss|json|sh|md|yml|yaml)' "$1" 2>/dev/null \
    | grep -E "^(src|prisma|scripts|e2e|tests|app|lib|components|pages|public|docs|content|middleware)${EXTRA:+|^($EXTRA)/}" \
    | sed 's|^\./||'
  grep -oE '(src|prisma|scripts|e2e|tests)/[][A-Za-z0-9_@()/.-]+/' "$1" 2>/dev/null | sed 's|/$||'
  [ -z "$EXTRA" ] || grep -oE "(^|[^][A-Za-z0-9_@()/.-])($EXTRA)/[][A-Za-z0-9_@()/.-]+/" "$1" 2>/dev/null \
    | sed -e 's|^[^][A-Za-z0-9_@()/.-]||' -e 's|/$||' | awk -F/ 'NF>=3'
}

# keep: on stdin, the paths this checkout can vouch for.
#
# A NEW FILE COUNTS, and that is the whole point of the directory test: the
# normal shape of a ticket is "add src/lib/thing.ts", which does not exist yet
# and is exactly the path the overlap rule needs — two siblings adding two
# different files under one directory are DISJOINT, while a bare directory
# scope contains them both. A path under a directory that does not exist is
# dropped instead: it is a typo, a rename, or another repo, and an invented
# path can only ever manufacture a disjoint that is not real.
keep() {
  if [ ! -d "$REPO" ]; then cat; return 0; fi
  local p d
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    if [ -e "$REPO/$p" ]; then printf '%s\n' "$p"; continue; fi
    d=$(dirname "$p")
    [ -d "$REPO/$d" ] && printf '%s\n' "$p"
  done
  # A dropped LAST path used to leave this function returning 1, and under
  # `set -o pipefail` that made the whole codegraph pipeline below look failed —
  # so the one real importer it had just found was thrown away by the fallback
  # arm. The filter's job is to filter; whether it dropped the last line is not
  # an error.
  return 0
}

prune() { awk -F/ '/\./ || NF>=3' | sort -u; }

write_list() { # write_list <source> <paths-file>
  mkdir -p "$PLANDIR" 2>/dev/null || return 1
  { printf 'SOURCE: %s\n' "$1"; cat "$2"; } > "$PLANDIR/.planned-files.new" 2>/dev/null \
    && mv "$PLANDIR/.planned-files.new" "$PLANDIR/planned-files.txt" 2>/dev/null
}

# >>> test-home reroute
# TEST FILES ARE THIS FLEET'S LARGEST MERGE-CONFLICT SURFACE (#580): 20 of 24
# unresolvable conductor cases were siblings appending cases to one shared
# tests/<area> file. This list is the first place the harness can say "not that
# file — YOUR file", because it is the list the executor is later handed.
#
# So a listed path that is a SHARED test file present in the checkout is
# replaced by this ticket's own per-ticket name, and the swap is written to the
# record bin/overlap-guard.sh and bin/run-build.sh read. The spelling of all of
# it — what a test path is, what per-ticket means, the record format, the kill
# switch — belongs to bin/lib/test-home-lib.sh and is not re-typed here.
# shellcheck source=bin/lib/test-home-lib.sh
[ -r "$HERE/lib/test-home-lib.sh" ] && . "$HERE/lib/test-home-lib.sh" 2>/dev/null

# A BUG FIX BELONGS NEXT TO THE CASE IT FIXES, so the kind decides before
# anything is rewritten. Resolved ONCE and lazily — the fork only happens for a
# ticket that actually named a shared test file, which is the minority of them.
# bin/kind-gate.sh is reused as-is rather than re-implemented: its precedence
# (the board's own labels/title outrank a KIND: line in the text) IS the order
# this needs, and a second spelling of "what kind of work is this" is exactly
# the drift that file exists to prevent.
TH_KIND=""
th_kind() {
  if [ -z "$TH_KIND" ]; then
    if [ -n "${PLANNED_FILES_KIND:-}" ]; then
      TH_KIND="$PLANNED_FILES_KIND"
    elif [ -x "$HERE/kind-gate.sh" ]; then
      mkdir -p "$TD/kind" 2>/dev/null
      [ -n "${PLANNED_FILES_META_FILE:-}" ] && [ -r "${PLANNED_FILES_META_FILE:-}" ] \
        && cp "$PLANNED_FILES_META_FILE" "$TD/kind/ticket-meta.json" 2>/dev/null
      cp "$BODY" "$TD/kind/plan.md" 2>/dev/null
      # rc is ignored on purpose: 2 is "a bug whose plan carries no
      # reproduction", which is a fine answer to "is this a bug?".
      TH_KIND=$("$HERE/kind-gate.sh" "$TD/kind" 2>/dev/null | sed -n 's/^KIND:[[:space:]]*//p' | tail -1)
    fi
    TH_KIND=$(printf '%s' "${TH_KIND:-unknown}" | tr 'A-Z' 'a-z')
    [ -n "$TH_KIND" ] || TH_KIND=unknown
  fi
  printf '%s\n' "$TH_KIND"
}

# A shared test file this ticket would otherwise write into. `-f`, not `-e`: the
# extractor also emits bare directory scopes (tests/level2-unit/sub), which match
# the test-path matcher, exist, and can never be rewritten to a file name.
th_candidate() {
  th_is_test_path "$1" || return 1
  [ -f "$REPO/$1" ] || return 1
  ! th_is_per_ticket "$1"
}

reroute_shared() { # reroute_shared <paths-file> — rewrites the file in place
  local f="${1:-}" p t n=0 seen=1 REC
  command -v th_enabled >/dev/null 2>&1 || return 0   # lib absent: the pass vanishes
  th_enabled "$HARNESS" || return 0
  [ -s "$f" ] || return 0
  while IFS= read -r p; do
    th_candidate "$p" && { seen=0; break; }
  done < "$f"
  [ "$seen" = 0 ] || return 0
  if [ "$(th_kind)" = bug ]; then
    say "bug ticket — shared test paths left as they are (a reproduction belongs next to the case it fixes)"
    return 0
  fi
  REC=$(th_record_path "$HARNESS" "$PROJECT" "$KEY")
  : > "$TD/reroute" 2>/dev/null || return 0
  while IFS= read -r p; do
    t=""
    th_candidate "$p" && t=$(th_per_ticket_path "$p" "$KEY" 2>/dev/null)
    # THE RECORD IS WRITTEN FIRST AND ITS rc DECIDES. th_record_add rc 1 means
    # "not rerouted", so the shared path stays: a list pointing at a per-ticket
    # file nothing recorded would send an executor somewhere no consumer knows
    # about.
    if [ -n "$t" ] && [ "$t" != "$p" ] && th_record_add "$REC" "$p" "$t"; then
      printf '%s\n' "$t" >> "$TD/reroute"; n=$((n + 1))
    else
      printf '%s\n' "$p" >> "$TD/reroute"
    fi
  done < "$f"
  sort -u "$TD/reroute" > "$TD/reroute.sorted" 2>/dev/null \
    && mv "$TD/reroute.sorted" "$f" 2>/dev/null
  rm -f "$TD/reroute" "$TD/reroute.sorted" 2>/dev/null
  [ "$n" -gt 0 ] && say "$n shared test path(s) rerouted to this ticket's own file(s), recorded in $REC"
  return 0
}
# <<< test-home reroute

T1="$TD/tier1"
extract "$BODY" | keep | prune > "$T1"

# ---- tier 2: one hop of importers ------------------------------------------
# `codegraph node -f <file> --symbols-only` prints one header line per file:
#   **src/lib/a.ts** — 3 symbols, used by 2 files: src/lib/b.ts, src/lib/c.ts
# That trailing list IS the direct-importer set, which is the one hop worth
# having: a ticket that edits a helper is a ticket whose blast radius is its
# callers, and those are the files a sibling slice is most likely to be editing
# too. Capped, because this is an optimisation and a repo with a big index
# should not turn a free tier into a minute of subprocesses.
CG="${CODEGRAPH_BIN:-codegraph}"
SOURCE=ticket-body
if [ -s "$T1" ] && [ -d "$REPO/.codegraph" ] && command -v "$CG" >/dev/null 2>&1; then
  n=0
  while IFS= read -r p; do
    [ "$n" -ge "${PLANNED_FILES_CG_MAX:-10}" ] && break
    n=$((n + 1))
    "$CG" node -p "$REPO" -f "$p" --symbols-only 2>/dev/null \
      | sed -nE 's/.*used by [0-9]+ files?: //p' | tr ',' '\n'
  done < "$T1" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | grep -v '^$' \
    | keep | prune > "$TD/cg" 2>/dev/null
  [ -e "$TD/cg" ] || : > "$TD/cg"
  if [ -s "$TD/cg" ] && [ -n "$(comm -13 "$T1" "$TD/cg" 2>/dev/null)" ]; then
    sort -u "$T1" "$TD/cg" > "$TD/tier2" && mv "$TD/tier2" "$T1"
    SOURCE=ticket-body+codegraph
  fi
fi

reroute_shared "$T1"
if [ -s "$T1" ]; then
  write_list "$SOURCE" "$T1" && say "$(grep -c . "$T1") path(s), SOURCE: $SOURCE"
  exit 0
fi

# FREE-ONLY CALLERS STOP HERE (P2, #2294 review I1). bin/lib/preplan-lib.sh
# :preplan_small_log runs this for a key whose pre-plan it just SKIPPED to save
# money; buying the list with a model call would put back a slice of what the
# skip saved. Tiers 1-2 found nothing, so nothing is written — the same answer
# an in-app board gets — and the next caller without the variable still owns
# tier 3.
if [ "${PLANNED_FILES_FREE_ONLY:-0}" = 1 ]; then
  say "free tiers found nothing and the caller is free-only — tier 3 not asked"
  exit 0
fi

# ---- tier 3: the floor model, once per ticket per window -------------------
MARK="$HARNESS/state/preplan-files/$PROJECT-$KEY.called"
TTL="${PLANNED_FILES_MODEL_TTL:-21600}"
mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null; }
if [ -e "$MARK" ]; then
  M=$(mtime "$MARK"); NOW=$(date -u '+%s')
  case "${M:-}" in ''|*[!0-9]*) M=$NOW ;; esac
  if [ $((NOW - M)) -lt "$TTL" ]; then
    say "floor call already made $(( (NOW - M) / 60 ))m ago — inside the ${TTL}s window, not calling again"
    exit 0
  fi
fi

# THE MODEL ID COMES FROM THE CATALOG. A `claude-…` string typed into this file
# is the bug the iron laws name: the fleet's model choices are data, and a lane
# that hardcodes one is a lane nobody can re-tier without a deploy. The floor
# tier is defined as "the cheapest Claude-family row the price catalog carries"
# — Claude-family because the claude lane is agent-call.sh's default runner and
# a vendor slug handed to it is a call that cannot be made. No catalog, no call:
# an unresolvable model is a skipped optimisation, never a guessed id.
CAT=""
for c in "${MODEL_PRICES:-}" "$HARNESS/state/model-prices.json" \
         "/root/harness-checkout/catalog/model-prices.json" \
         "$HARNESS/catalog/model-prices.json" "$HERE/../catalog/model-prices.json"; do
  [ -n "$c" ] && [ -r "$c" ] && { CAT="$c"; break; }
done
MODEL="${PLANNED_FILES_MODEL:-}"
if [ -z "$MODEL" ] && [ -n "$CAT" ]; then
  MODEL=$(python3 - "$CAT" <<'PYEOF' 2>/dev/null || true
import json, sys
try:
    rows = json.load(open(sys.argv[1]))["per_token"]
except Exception:
    sys.exit(1)
cand = [(v["prompt"], k) for k, v in rows.items()
        if "/" not in k and isinstance(v, dict)
        and str(v.get("slug", "")).startswith("anthropic/")
        and isinstance(v.get("prompt"), (int, float))]
if not cand:
    sys.exit(1)
print(min(cand)[1])
PYEOF
)
fi
[ -n "$MODEL" ] || { say "no floor model resolvable from the price catalog — not guessing an id"; exit 0; }

# The window is burned BEFORE the call. Everything after this line is allowed to
# fail; none of it is allowed to re-bill on the next tick.
#
# AND IF THE MARKER CANNOT BE WRITTEN, THE CALL DOES NOT HAPPEN. A billable call
# with no persisted "have we already paid for this?" record is the shape that
# turned $1,678 of transcription into ~99% waste: the guard exists, it just never
# becomes true, so every tick buys the same answer again. A read-only state dir
# is a skipped optimisation, not a reason to spend.
mkdir -p "$(dirname "$MARK")" 2>/dev/null
date -u '+%Y-%m-%dT%H:%M:%SZ' > "$MARK" 2>/dev/null \
  || { say "cannot write the dedup marker at $MARK — not calling the model, because a call we cannot record is a call we will make again every tick"; exit 0; }

# PATH VOCABULARY, capped at 4KB (catalog/context-budgets.json states the cap).
# The index is a generated file in this repo and in any repo that copies the
# BH-1175 layout, so a checkout that has not regenerated it has no README at
# all. The entry FILES are what is committed, and they carry the same rows, so
# they are the fallback rather than sending the model in with no vocabulary.
VMAP="$REPO/docs/verification-map/README.md"
ENTRIES="$REPO/docs/verification-map/entries"
HINT=""
if [ -r "$VMAP" ]; then
  HINT="

The repository's feature index (docs/verification-map/README.md), for path vocabulary only:
$(head -c 4000 "$VMAP" 2>/dev/null)"
elif [ -d "$ENTRIES" ]; then
  HINT="

The repository's feature index (docs/verification-map/entries/, the committed source of the generated index), for path vocabulary only:
$(find "$ENTRIES" -maxdepth 1 -type f -name '*.md' 2>/dev/null | LC_ALL=C sort -V | xargs cat 2>/dev/null | head -c 4000)"
fi

OUT="$TD/model-out"
"$HARNESS/bin/agent-call.sh" preplan-files "$PROJECT" "$MODEL" "${PLANNED_FILES_MODEL_TIMEOUT:-180}" "$OUT" \
  "Read the ticket below and answer with NOTHING BUT a list of repo-relative file paths, one per line, that implementing it would most likely touch. No prose, no bullets, no backticks, no explanation, no header. A path that does not yet exist is fine and expected — name it where it would go. If you genuinely cannot tell, answer with nothing at all; a guess is worse than silence here, because this list is used to decide whether two pieces of work can run at the same time.

TICKET $KEY:
$(head -c 12000 "$BODY")$HINT" >/dev/null 2>&1

extract "$OUT" | keep | prune > "$TD/tier3" 2>/dev/null || : > "$TD/tier3"
reroute_shared "$TD/tier3"
if [ -s "$TD/tier3" ]; then
  write_list model-floor "$TD/tier3" && say "$(grep -c . "$TD/tier3") path(s) from the floor model ($MODEL), SOURCE: model-floor"
else
  # The third outcome, written down rather than retried: the call was made, it
  # was billed, and it produced nothing usable. The marker above already says
  # so, so the next tick reads this ticket as answered.
  say "floor model ($MODEL) returned no usable path — terminal for this window, not retried"
fi
exit 0
