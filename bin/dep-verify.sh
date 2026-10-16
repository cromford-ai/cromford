#!/bin/bash
# bin/dep-verify.sh <project> <child> <blocker>
#   stdout: exactly one line — `HARD <reason>` | `SOFT <reason>` | `UNKNOWN <reason>`
#   exit 0 always. UNKNOWN is the honest answer, never a failure.
#
# WHAT THIS IS FOR (W2-G, the operator, 2026-09-14: "how do we do that by default?").
# `Blocked-by: #N` is a CLAIM the plan author made once, by hand, before either
# slice existed. It is treated as an order everywhere else in this harness, and
# it over-declares: tonight's project-5 wave #666-#678 declares five chain
# levels, and at 60-75 minutes a level that is five sequential hours of a box
# that is otherwise idle — while children like the brain map and the lifecycle
# rollup share no files with their parents at all. The lever for widening that
# wave was a human editing issue bodies. This script is the lever moving into
# the harness: it CHECKS the claim, and the caller widens the wave itself.
#
# SOFT NEEDS BOTH HALVES, AND BOTH ARE EVIDENCE:
#   file      the child's pre-plan planned-files list is DISJOINT from the
#             blocker's file set — its open PR's changed files, else its merged
#             PR's, else the blocker's own pre-plan list. Same overlap rule
#             bin/conflict-check.sh and bin/plan-overlap.sh apply.
#   semantic  the child's own pre-plan says so: `DEPENDS: #N soft — <reason>`
#             (prompts/plan-contract.md §7). hard = this slice imports, calls,
#             extends or migrates on top of code #N adds. soft = ordering
#             preference only.
#
# THE SECOND SEMANTIC HALF (BH-499). With the speculative pre-plan lane off
# there is no plan.md to carry a DEPENDS line, so a list written by
# bin/planned-files-cheap.sh says which tier produced it — `SOURCE: ticket-body`
# or `ticket-body+codegraph` — and for those two the semantic half is the
# child body's own silence: no `Needs:` and no `(hard)` anywhere in it. A
# `SOURCE: model-floor` list is deliberately NOT enough: it may say HARD on an
# overlap and never SOFT on a disjoint. See the closing block.
#
# Missing either piece is UNKNOWN. What the caller does with UNKNOWN is its
# DEP_UNKNOWN_MODE (bin/lib/dep-verify-lib.sh:dep_unknown_mode — default `soft`
# since 2026-09-16, the operator: "there should be no cap"; `hard` is the original
# fail-closed wait). This script only answers; it never decides.
#
# THE AUTHOR'S ESCAPE HATCH outranks all of it, with no verification at all:
# `Blocked-by: #N (hard)` or `Needs: #N` in the child's issue body is HARD, full
# stop. Someone who knows the child cannot compile without #N writes one of
# those and this script does not argue.
#
# THE CACHE (state/dep-verify/<project>/<child>-<blocker>) holds the verdict and
# the EVIDENCE FINGERPRINT that produced it: the child's blocker declarations,
# its plan.md, its planned-files list, and the blocker's evidence source (its
# PR's head sha, or its own plan.md). Either plan moving re-verifies; nothing
# moving costs one `gh pr list` and no `pulls/N/files` call at all.
#
# GitHub-Issues boards only — in-app boards have no Blocked-by convention, so
# they resolve no repo and this answers UNKNOWN without spending anything.
#
# Kill flag: DEP_VERIFY=0 in env/global.env, or flags/dep-verify-off. Either one
# makes this answer `UNKNOWN dep-verify is off` before reading anything, and the
# callers then behave exactly as they did before this script existed.
# DEP_VERIFY_DRY_RUN=1 prints the verdict and writes no cache row.
#
# Overrides, all documented because the dry-run proof and the fixtures use them:
#   DEP_CHILD_FILES       a hand-written planned-files list, instead of the
#                         child's pre-plan (this is how the file half is driven
#                         before any pre-plan exists)
#   DEP_CHILD_BODY_FILE   the child's issue body, when the caller already has it
#                         (bin/unblocked-children.sh does — one fetch, not N)
#   DEP_CHILD_PLAN        the child's plan.md, instead of the pre-plan's
#   DEP_PRS_FILE          the repo's PR list as JSON, instead of asking gh
#
# AN UNREADABLE ANSWER IS UNKNOWN, AND SAYS SO (BH-782). Both GitHub reads here
# go through bin/lib/gh-rest.sh. A failed PR list used to read as "the blocker
# has no PR" and the verdict said "no file evidence for #N", which reads like a
# fact about the blocker; a failed issue-body read left an EMPTY body, which
# silently removed the author's `Blocked-by … (hard)` escape hatch. Both now
# answer `UNKNOWN gh HTTP <status> …`. RECORD still refuses to cache UNKNOWN, so
# an outage cannot freeze into state/dep-verify/ — the next tick re-asks. And a
# tick whose PR list failed is not SERVED from the cache either: the fingerprint
# cannot tell "this blocker has no PR" from "we could not look", so one healthy
# tick would otherwise let every later 403 replay a cached SOFT — a release — and
# never reach the UNKNOWN below.
#
# gh-rest: no-graphql
set -uo pipefail
PROJECT="${1:?usage: dep-verify.sh <project> <child> <blocker>}"
CHILD="${2:?child issue number}"
BLOCKER="${3:?blocker issue number}"
HARNESS="${HARNESS:-/root/harness}"
HERE="$(cd "$(dirname "$0")" && pwd)"

SAY() { printf '%s %s\n' "$1" "$2"; exit 0; }

case "$CHILD$BLOCKER" in *[!0-9]*) SAY UNKNOWN "child/blocker must be issue numbers" ;; esac

# shellcheck source=bin/lib/dep-verify-lib.sh
[ -r "$HERE/lib/dep-verify-lib.sh" ] && . "$HERE/lib/dep-verify-lib.sh" 2>/dev/null
command -v dep_verify_on >/dev/null 2>&1 || SAY UNKNOWN "bin/lib/dep-verify-lib.sh is not readable on this box"
# shellcheck source=bin/lib/preplan-lib.sh
[ -r "$HERE/lib/preplan-lib.sh" ] && . "$HERE/lib/preplan-lib.sh" 2>/dev/null
# The REST contract (#780). Absent, every read below answers UNKNOWN naming the
# missing lib rather than falling through to a GraphQL call.
# shellcheck source=bin/lib/gh-rest.sh
[ -r "$HERE/lib/gh-rest.sh" ] && . "$HERE/lib/gh-rest.sh" 2>/dev/null
# BH-6977: a definite verdict is also sent as a ticket_edges row. Fail-open,
# prints nothing; absent, RECORD sends nothing.
# shellcheck source=bin/lib/ticket-edges.sh
[ -r "$HERE/lib/ticket-edges.sh" ] && . "$HERE/lib/ticket-edges.sh" 2>/dev/null

[ "$(dep_verify_on "$HARNESS")" = 1 ] || SAY UNKNOWN "dep-verify is off (DEP_VERIFY=0 or flags/dep-verify-off)"
DRY=$(dep_verify_dry "$HARNESS")

TD=$(mktemp -d) || SAY UNKNOWN "no temp dir"
trap 'rm -rf "$TD"' EXIT

# ---- the child's own plan: the cheap half, and the common early exit --------
# A child with no pre-plan has no file evidence and cannot have a DEPENDS line,
# so it is UNKNOWN whatever GitHub would have said. Answering it here is what
# keeps this free to call on every blocked child of every tick: no token, no
# request, no cache row. The escape hatch used to be read AFTER this, because
# UNKNOWN and HARD were the same wait — but under DEP_UNKNOWN_MODE=soft they are
# not, and an author who wrote `Blocked-by: #N (hard)` on a child nobody has
# pre-planned yet must still be obeyed. So when the caller already staged the
# body (bin/unblocked-children.sh always does), the hatch is read HERE, which
# costs nothing: no request, and no cache row because there is no evidence to
# fingerprint yet. The later read stays for callers that did not stage it.
if [ -n "${DEP_CHILD_BODY_FILE:-}" ] && [ -r "${DEP_CHILD_BODY_FILE:-}" ] \
   && dep_declared_hard "$BLOCKER" "$DEP_CHILD_BODY_FILE"; then
  SAY HARD "#$CHILD declares #$BLOCKER hard in its own body (Blocked-by … (hard) / Needs:) — not verified, by design"
fi
PFX=""
command -v preplan_key_prefix >/dev/null 2>&1 && PFX=$(preplan_key_prefix "$HARNESS" "$PROJECT" 2>/dev/null || true)
PLANDIR=""
[ -n "$PFX" ] && PLANDIR="$HARNESS/plans/$PROJECT-$PFX-$CHILD"
CPLAN="${DEP_CHILD_PLAN:-${PLANDIR:+$PLANDIR/plan.md}}"
CSRC="${DEP_CHILD_FILES:-${PLANDIR:+$PLANDIR/planned-files.txt}}"
CFILES="$TD/child-files"
dep_norm "${CSRC:-/nonexistent}" "$CFILES" \
  || SAY UNKNOWN "no planned-files list for child #$CHILD (${PFX:+$PFX-$CHILD }has no pre-plan yet)"
# WHICH TIER WROTE THE LIST (BH-499). Empty for a list that came out of a real
# plan.md; `ticket-body` / `ticket-body+codegraph` / `model-floor` for one
# bin/planned-files-cheap.sh extracted. The closing block is the only place this
# changes an answer, and it changes it in exactly one direction — see there.
CSOURCE=""
command -v dep_list_source >/dev/null 2>&1 && CSOURCE=$(dep_list_source "${CSRC:-/nonexistent}" 2>/dev/null || true)

# ---- the blocker's evidence source -----------------------------------------
REPO=$(dep_repo_for "$HARNESS" "$PROJECT" 2>/dev/null || true)
[ -n "$REPO" ] || SAY UNKNOWN "no GitHub-Issues repo for $PROJECT — Blocked-by is not a convention there"

# Whichever token can SEE this repo, exactly as bin/unblocked-children.sh does:
# the hub's default PAT 404s on example-org/project-5, and an empty PR list there
# would read as "the blocker has no PR" rather than "we cannot look".
# shellcheck source=bin/lib/gh-repo-token.sh
[ -r "$HERE/lib/gh-repo-token.sh" ] && . "$HERE/lib/gh-repo-token.sh" 2>/dev/null
command -v gh_repo_use_token >/dev/null 2>&1 && { gh_repo_use_token "$REPO" >/dev/null 2>&1 || true; }
# Then the App token, AFTER the probe so the probe stays the fallback.
# shellcheck source=bin/lib/gh-app-auth.sh
[ -r "$HERE/lib/gh-app-auth.sh" ] && . "$HERE/lib/gh-app-auth.sh" 2>/dev/null
command -v gh_auth_for >/dev/null 2>&1 && gh_auth_for "$REPO" || true

PRS="$TD/prs.json"
# Set when the PR list could not be READ, as opposed to genuinely holding no
# matching PR. Answered below, after the two checks that need no PR list at all.
PRS_UNKNOWN=""
if [ -n "${DEP_PRS_FILE:-}" ] && [ -s "${DEP_PRS_FILE:-}" ]; then
  cp "$DEP_PRS_FILE" "$PRS"
elif ! command -v gh_rest_pr_list >/dev/null 2>&1; then
  PRS_UNKNOWN="lib missing (bin/lib/gh-rest.sh is not readable on this box)"
  printf '[]' > "$PRS"
else
  # Token discipline: the five fields the matcher needs, never a default human
  # dump. state=all, because a MERGED parent's files are the second-best
  # evidence and the only evidence once its branch is gone.
  #
  # `> file`, never `$( )`: GH_REST_STATUS must survive into this shell.
  PRRC=0
  gh_rest_pr_list "$REPO" all "" 100 > "$TD/prs.raw" || PRRC=$?
  if [ "$PRRC" = 0 ]; then
    # REST says MERGED with `merged_at`, not with a state word — a merged PR's
    # `state` is "closed", and dep-verify ranks on OPEN/MERGED below.
    jq -c '[.[] | {number, title, headRefName: .head.ref, headRefOid: .head.sha,
                   state: (if .merged_at != null then "MERGED" else (.state|ascii_upcase) end)}]' \
       "$TD/prs.raw" > "$PRS" 2>/dev/null || { PRS_UNKNOWN="HTTP 200 (the PR list body would not parse)"; printf '[]' > "$PRS"; }
  else
    PRS_UNKNOWN="HTTP ${GH_REST_STATUS:-000}${GH_REST_REASON:+ $GH_REST_REASON}"
    printf '[]' > "$PRS"
  fi
fi
[ -s "$PRS" ] || printf '[]' > "$PRS"

# The two names bin/run-build.sh gives its work — the branch it cuts
# (ticket/<key-lowercased>, plus the -r<n> retry suffix) and the PR title it
# opens (<KEY>: <subject>) — matched on the ISSUE NUMBER, so this stays free of
# the per-project key prefix. Same matcher bin/unblocked-children.sh uses.
BPR=$(BLOCKER="$BLOCKER" python3 - "$PRS" <<'PYEOF' 2>/dev/null || true
import json, os, re, sys
try:
    with open(sys.argv[1]) as f:
        prs = json.load(f)
    if not isinstance(prs, list):
        prs = []
except Exception:
    prs = []
n = int(os.environ["BLOCKER"])
br = re.compile(r"^ticket/[a-z0-9]+-%d(-r\d+)?$" % n, re.IGNORECASE)
ti = re.compile(r"^[A-Za-z]+-%d:" % n)
best = None
for p in prs:
    if not isinstance(p, dict):
        continue
    if not (br.match(str(p.get("headRefName", ""))) or ti.match(str(p.get("title", "")))):
        continue
    st = str(p.get("state", "")).upper()
    rank = {"OPEN": 0, "MERGED": 1}.get(st, 2)
    if best is None or rank < best[0]:
        best = (rank, p)
if best and best[0] < 2:
    p = best[1]
    print("%s\t%s\t%s" % (p.get("number", ""), str(p.get("state", "")).upper(),
                          str(p.get("headRefOid", "") or "")))
PYEOF
)
BNUM=$(printf '%s' "$BPR" | cut -f1); BSTATE=$(printf '%s' "$BPR" | cut -f2); BOID=$(printf '%s' "$BPR" | cut -f3)
BPLANDIR=""
[ -n "$PFX" ] && BPLANDIR="$HARNESS/plans/$PROJECT-$PFX-$BLOCKER"
if [ -n "$BNUM" ]; then
  BSRCID="pr#$BNUM@${BOID:-nohead}"
else
  BSRCID="plan@$(dep_sha "${BPLANDIR:+$BPLANDIR/planned-files.txt}")"
fi

# ---- the cache -------------------------------------------------------------
# The fingerprint is the EVIDENCE, not the clock: the child's blocker
# declarations, its plan, its file list, and whatever the blocker's file set is
# currently drawn from. Either plan moving invalidates it; nothing moving costs
# no pulls/N/files call at all.
BODY="${DEP_CHILD_BODY_FILE:-}"
DECL="$TD/decl"
if [ -n "$BODY" ] && [ -r "$BODY" ]; then
  grep -iE "^[[:space:]>*_#-]*(blocked[- ]by|needs|after)\b" "$BODY" > "$DECL" 2>/dev/null || : > "$DECL"
else
  : > "$DECL"
fi
# CSOURCE IS PART OF THE EVIDENCE, not a label on it: the same paths carrying a
# `SOURCE: ticket-body` header and carrying none are two different answers now,
# and dep_norm strips the header before CFILES is hashed — so without this the
# two are one fingerprint and the second one replays the first one's verdict.
# |v2 because the meaning of a cached row changed with it.
FP=$(printf '%s%s%s%s' "$(dep_sha "$DECL" "${CPLAN:-/nonexistent}" "$CFILES")" "$CSOURCE" "$BSRCID" "|v2" \
     | sha256sum 2>/dev/null | cut -c1-32)
CACHE=$(dep_cache_file "$HARNESS" "$PROJECT" "$CHILD" "$BLOCKER")
# A DEGRADED TICK MUST NOT BE SERVED FROM THE CACHE (BH-782 review r2). The
# fingerprint above is built from BSRCID, and BSRCID was read out of $PRS — which
# on a failed list is the `[]` this script wrote itself. So a blocker with no PR
# fingerprints IDENTICALLY whether the list said "no PR" or could not be read at
# all, and one healthy tick is enough to make every later 403 replay that tick's
# SOFT with rc 0. SOFT is a RELEASE: the child builds on the default branch on
# the strength of a read that never happened, and §2b below — the whole point of
# this change — is never reached. UNKNOWN is never cached for the same reason;
# this is that rule applied to the read rather than to the verdict. The cost of
# skipping the cache here is one `pulls?state=all` call on a tick that is
# already failing.
if [ -n "$FP" ] && [ -z "$PRS_UNKNOWN" ] && [ -s "$CACHE" ] && [ "$(sed -n 1p "$CACHE")" = "fp=$FP" ]; then
  CACHED=$(sed -n 2p "$CACHE")
  case "$CACHED" in HARD\ *|SOFT\ *|UNKNOWN\ *) printf '%s\n' "$CACHED"; exit 0 ;; esac
fi

# From here on the answer is computed. RECORD prints it, and caches it when it
# is a DEFINITE one.
#
# UNKNOWN IS NEVER CACHED. It does not mean "the answer is no", it means "we
# could not answer" — and the commonest reason is a transient one this
# fingerprint cannot see (a 401 on the files call, a PR list that timed out).
# Writing it down would freeze that outage into the cache until one of the two
# plans happened to move, which is a wave that stays narrow for a reason nobody
# can find. Re-asking costs one request.
RECORD() {
  if [ "$DRY" != 1 ] && [ -n "$FP" ] && [ "$1" != UNKNOWN ]; then
    mkdir -p "$(dep_cache_dir "$HARNESS" "$PROJECT")" 2>/dev/null \
      && printf 'fp=%s\n%s %s\n' "$FP" "$1" "$2" > "$CACHE" 2>/dev/null
    command -v te_put_verdict >/dev/null 2>&1 && te_put_verdict "$PROJECT" "$CHILD" "$BLOCKER" "$1" >/dev/null 2>&1
  fi
  # Every terminal path after the arm lands here — this function is the script's end.
  command -v gh_auth_reset >/dev/null 2>&1 && gh_auth_reset
  SAY "$1" "$2"
}

# ---- 1. the author's escape hatch ------------------------------------------
# Set when the body could not be READ, as opposed to a body that carries no
# marker. Answered in §3b, after every check that can still reach a HARD.
BODY_UNKNOWN=""
if [ -z "$BODY" ] || [ ! -r "$BODY" ]; then
  BODY="$TD/body"
  : > "$BODY"
  # AN UNREADABLE BODY MUST NOT READ AS AN EMPTY ONE. The marker below it is the
  # author overriding every other piece of evidence in this script, so losing it
  # silently is the worst answer available.
  #
  # NOT ANSWERED HERE, THOUGH (BH-782 review r2). RECORD is terminal, so a
  # RECORD at this line throws away the two verdicts that follow it and never
  # needed this read: the `DEPENDS: #N hard` line in the child's LOCAL pre-plan
  # file, and the file overlap computed from a PR list that may well have been
  # read successfully. Both of those are HARD — a hold — and UNKNOWN is not:
  # DEP_UNKNOWN_MODE defaults to soft, and soft RELEASES the child to build on
  # the default branch. Turning a fail-closed HARD into a release because
  # github.com answered 403 is the one expensive outcome this whole script
  # exists to avoid.
  if ! command -v gh_rest >/dev/null 2>&1; then
    BODY_UNKNOWN="gh lib missing"
  elif command -v _gh_rest_args_ok >/dev/null 2>&1 && ! _gh_rest_args_ok "$REPO"; then
    # The raw GET below interpolates $REPO into the path, so it misses the shape
    # check every gh_rest_* helper does for free. Operator-controlled input, so
    # this guards the sink rather than an attacker.
    BODY_UNKNOWN="bad repo slug in fleet.conf"
  else
    BRC=0
    gh_rest GET "repos/$REPO/issues/$CHILD" > "$TD/child.json" || BRC=$?
    if [ "$BRC" != 0 ]; then
      BODY_UNKNOWN="gh HTTP ${GH_REST_STATUS:-000}${GH_REST_REASON:+ $GH_REST_REASON}"
    elif ! jq -r '.body // ""' "$TD/child.json" > "$BODY" 2>/dev/null; then
      BODY_UNKNOWN="gh HTTP ${GH_REST_STATUS:-000} (the issue body would not parse)"
      : > "$BODY"
    fi
  fi
fi
if dep_declared_hard "$BLOCKER" "$BODY"; then
  RECORD HARD "#$CHILD declares #$BLOCKER hard in its own body (Blocked-by … (hard) / Needs:) — not verified, by design"
fi

# ---- 2. the semantic half, when it says hard -------------------------------
# Checked before the file half only for the HARD answer: if the plan that wrote
# the slice says it sits on top of the blocker's code, no file list changes that
# and the `pulls/N/files` call is not worth spending.
DEP=$(dep_depends_line "$BLOCKER" "${CPLAN:-/nonexistent}" 2>/dev/null || true)
DKIND=$(printf '%s' "$DEP" | cut -d' ' -f1); DWHY=$(printf '%s' "$DEP" | cut -d' ' -f2-)
[ "$DKIND" = hard ] && RECORD HARD "the pre-plan for #$CHILD declares DEPENDS: #$BLOCKER hard — $DWHY"

# ---- 2b. the PR list we could not read -------------------------------------
# Answered HERE and not at the read: the two checks above need no PR list at
# all, so an outage must not cost a verdict they could have given. Only the file
# half below depends on it, and with an unreadable list the honest answer is not
# "the blocker has no PR" — it is "we could not look".
[ -n "$PRS_UNKNOWN" ] \
  && RECORD UNKNOWN "gh $PRS_UNKNOWN — the PR list for #$BLOCKER could not be read this tick${BODY_UNKNOWN:+; the body of #$CHILD could not be read either — $BODY_UNKNOWN}"

# ---- 3. the file half ------------------------------------------------------
BFILES="$TD/blocker-files"; : > "$TD/blocker-raw"
BWHERE=""
if [ -n "$BNUM" ]; then
  if gh api "repos/$REPO/pulls/$BNUM/files" --paginate 2>/dev/null \
       | python3 -c 'import json,sys
try: d=json.load(sys.stdin)
except Exception: d=[]
for r in (d if isinstance(d,list) else []):
    if isinstance(r,dict) and r.get("filename"): print(r["filename"])' > "$TD/blocker-raw" 2>/dev/null \
     && [ -s "$TD/blocker-raw" ]; then
    BWHERE="#$BNUM's $(printf '%s' "$BSTATE" | tr 'A-Z' 'a-z') PR"
  fi
fi
if [ ! -s "$TD/blocker-raw" ] && [ -n "$BPLANDIR" ] && [ -s "$BPLANDIR/planned-files.txt" ]; then
  cp "$BPLANDIR/planned-files.txt" "$TD/blocker-raw"
  BWHERE="#$BLOCKER's own pre-plan"
fi
# "No file evidence" is a sentence about the BLOCKER, so when the child's body
# was also unreadable this tick the line says both — otherwise the operator reads
# a fact about #BLOCKER and never learns a read failed.
dep_norm "$TD/blocker-raw" "$BFILES" \
  || RECORD UNKNOWN "no file evidence for #$BLOCKER (no PR with changed files, no pre-plan list)${BODY_UNKNOWN:+; and the body of #$CHILD was unreadable this tick — $BODY_UNKNOWN}"

HITS=$(dep_overlap "$CFILES" "$BFILES")
if [ -n "$HITS" ]; then
  RECORD HARD "planned files overlap $BWHERE: $(printf '%s\n' "$HITS" | sed 's/ ~ /~/' | tr '\n' ',' | sed 's/,*$//')"
fi

# ---- 3b. the body we could not read ----------------------------------------
# LAST of the checks, and deliberately so. Everything above it can still answer
# HARD (a hold) from evidence this read has no part in: the child's own pre-plan
# on local disk, and the blocker's changed files. Everything BELOW it can only
# answer SOFT or UNKNOWN, and a SOFT is a release. So the honest place to say
# "the author's escape hatch could not be checked" is here: the outage costs the
# `Blocked-by … (hard)` marker and nothing else, which is what §1's comment
# claims it costs.
[ -n "$BODY_UNKNOWN" ] \
  && RECORD UNKNOWN "$BODY_UNKNOWN — the body of #$CHILD is unreadable this tick (the hard marker cannot be checked)"

NC=$(grep -c . "$CFILES"); NB=$(grep -c . "$BFILES")
[ "$DKIND" = soft ] \
  && RECORD SOFT "planned files are disjoint from $BWHERE ($NC vs $NB paths) and the pre-plan declares DEPENDS: #$BLOCKER soft — $DWHY"

# ---- 4. the deterministic list stands in for the missing DEPENDS line ------
# WHY THIS EXISTS (BH-499). The rule above — disjoint files but no DEPENDS line
# is UNKNOWN — was written when the only file list in the world came from a FULL
# pre-plan, which also carries the DEPENDS line. A list without one meant a
# planner had read the code and declined to say, and that silence is not
# evidence of anything.
#
# bin/planned-files-cheap.sh's list breaks that assumption in the ticket's
# favour: it is extracted from the issue body deterministically and CANNOT carry
# a DEPENDS line, because no model ever read the code. Demanding one there
# demands a sentence nobody was asked to write, and the result is the state this
# ticket exists to end — with the speculative pre-plan lane off, every child is
# UNKNOWN, every Blocked-by line is obeyed, and a wave runs exactly as wide as
# its hand-typed graph.
#
# So the semantic half is supplied by the body's own silence, and it is narrow
# on purpose:
#   * only the DETERMINISTIC tiers. A `model-floor` list is a model guessing
#     paths out of a body that named none — the weakest thing in the system. It
#     is still good enough to say HARD on an overlap above, and never good
#     enough to say SOFT on a disjoint.
#   * no Needs: / (hard) ANYWHERE in the body, not just for this blocker
#     (dep_body_has_hard_marker). An author who wrote one of those has said the
#     slice is not free-standing; inferring independence from a list they never
#     wrote is the wrong direction to be confident in.
# The escape hatch in step 1 still outranks all of it.
case "$CSOURCE" in
  ticket-body|ticket-body+codegraph)
    # Stale-library safety, same shape bin/agent-call.sh uses for its own
    # helpers: a box whose sync has not landed the new lib must fall through to
    # the old UNKNOWN rather than reach SOFT with the marker check missing.
    command -v dep_body_has_hard_marker >/dev/null 2>&1 \
      || RECORD UNKNOWN "planned files are disjoint from $BWHERE ($NC vs $NB paths) and the list is deterministic (SOURCE: $CSOURCE), but this box's dep-verify-lib has no marker check"
    if dep_body_has_hard_marker "$BODY"; then
      RECORD UNKNOWN "planned files are disjoint from $BWHERE ($NC vs $NB paths) and the list is deterministic (SOURCE: $CSOURCE), but #$CHILD's body carries a Needs:/(hard) marker — not inferring independence over the author"
    fi
    RECORD SOFT "planned files are disjoint from $BWHERE ($NC vs $NB paths); the list is the deterministic one (SOURCE: $CSOURCE) and #$CHILD's body carries no Needs:/(hard) marker"
    ;;
esac
RECORD UNKNOWN "planned files are disjoint from $BWHERE ($NC vs $NB paths) but the pre-plan for #$CHILD declares no DEPENDS line for #$BLOCKER"
