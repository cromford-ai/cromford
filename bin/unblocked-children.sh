#!/bin/bash
# bin/unblocked-children.sh <project>  — stdin: gate-diff.sh output; stdout: UNBLOCKED / STACKABLE lines
#
# A child ticket carries "Blocked-by: #N" and is launched only when #N closes.
# When the harness itself closes #N (a close-out in a sweep) the same tick
# launches the child. When #N closes from OUTSIDE a tick — a PR squash-merged
# by hand, GitHub's "closes #N" — the board-changed tick sees only #N in its
# diff, notes "already commented, closed" and moves on; nothing ever re-reads
# the child. TK-332 sat 3.5 h after #331 merged that way (2026-09-12).
#
# This script is the deterministic expansion: for every diff line that says a
# ticket went OPEN -> CLOSED, list the OPEN ai-build issues whose body names it
# in a Blocked-by line and whose EVERY blocker is now closed. The tick's prompt
# gets them as explicit reading-list lines, so launching them is the SOP's
# ordinary queue rule, not a hope that the model follows a reference.
#
# STACKABLE — THE SECOND CLASS (the operator, 2026-09-14). Waiting for the blocker to
# CLOSE costs a full chain level per ticket: tonight TK-563..567 all sat behind
# #611's open PR and TK-558/559 behind 555/557, and a chain level is 60-75 min
# of wall clock on project-5. But the parent's WORK exists the moment its PR is
# open — the child can be cut from that branch and reviewed against it, and
# GitHub retargets the child PR to main by itself when the parent merges and its
# branch is deleted. So a child whose one still-open blocker already has an open
# harness PR is emitted as STACKABLE with the base branch to build on, and the
# chain levels overlap instead of queueing. Emitted only while the blocker's PR
# is genuinely open and the child has no PR of its own yet.
#
# DEP-VERIFIED SOFT — THE THIRD CLASS (W2-G, the operator, 2026-09-14: "how do we do
# that by default?"). Both classes above still OBEY the Blocked-by line; they
# only differ on how early they obey it. But the line is a CLAIM the plan author
# typed once, before either slice existed, and it over-declares: tonight's
# project-5 wave #666-#678 declares five chain levels when several children
# share no files with their parent at all and could build on main right now. The
# lever for widening that wave was a human editing issue bodies.
#
# So for a child whose blockers are all still open, bin/dep-verify.sh is asked
# about each one, and a child whose EVERY open blocker comes back SOFT is
# emitted as UNBLOCKED — build on main, now — with the verified blockers named
# in the line. SOFT needs two pieces of evidence (file-disjoint AND the child's
# own pre-plan declaring `DEPENDS: #N soft`), and anything missing is UNKNOWN.
# HARD keeps today's behaviour to the letter: STACKABLE if the parent has an
# open PR, otherwise a wait. The launch is recorded on the child's own thread,
# once, so the decision is readable by the client rather than only by this
# box's log.
#
# UNKNOWN IS NOT A CAP (the operator, 2026-09-16). Until this date UNKNOWN was obeyed
# exactly like HARD, and it was the commonest verdict by far: a decomposed
# child has no pre-plan until the pre-plan lane reaches it, so "no planned-files
# list for child" held the whole wave. project-5 at 05:04Z had 22 of its 49
# open tickets logged `DEP_HARD … UNKNOWN, treated as hard` while the Fly pool
# cap was already 0/unlimited — the dependency check had become the throughput
# ceiling the pool cap was removed to get rid of. the operator: "There should be no
# cap, let's remove the cap." So DEP_UNKNOWN_MODE (env/global.env, default
# `soft`; bin/lib/dep-verify-lib.sh:dep_unknown_mode) decides what an UNKNOWN
# pair does: `soft` treats it exactly like SOFT — the child is released to
# build on the default branch now, and a real overlap the missing evidence
# would have caught is what the conductor's self-rebase exists to resolve;
# `hard` is the old wait. Pairs the evidence actually calls HARD are HARD
# under both settings.
#
# THE CLOSURE NO DIFF CAN MENTION (2026-09-14). Both trigger stories above end
# at a board diff line, and the diff is computed over the ai-build fingerprint —
# so a parent that LOST the label is invisible to it twice over. The size gate
# strips ai-build from a decomposed parent (project-5 #667, #668 are OPEN and
# unlabelled), which used to read here as "not in the list, therefore CLOSED":
# #669's blockers both looked closed, nothing in the diff had closed them, and
# the child was dropped without ever being judged — while the triage session,
# reading the body, correctly saw #667 open and left it blocked. Both halves are
# fixed: a blocker the label-scoped list does not carry is FETCHED by number, so
# an open parent reads OPEN; and when its blockers really are all closed, the
# child is released by this pass itself rather than by a diff line that can
# never arrive. That release is rate-limited by a marker
# (state/dep-verify/<project>/<child>.unblocked, re-offered after
# UNBLOCKED_REMIND_S, default 6h) so a child nobody launched is offered again
# instead of once and never — the line's own "if no PR or build already covers
# it" stays the guard.
#
# THE PARENT OF A SPLIT (2026-09-15). One write was added to this pass, and it
# is the only one: bin/decompose-parent-close.sh closes a decomposed parent
# whose children have ALL closed, with a comment listing them and their PRs. It
# lives on this path because the fact that releases a chain is the PARENT's
# number — `Blocked-by: #670`, not `Blocked-by: #<one of 670's children>` — so
# closing it anywhere else would need a second pass to notice. Here, its number
# joins this tick's closure set and its dependents come out as UNBLOCKED lines
# in the same output. Still no launch, and still no model call.
#
# THE CHAIN TAG (BH-3684). A STACKABLE line whose child and blocker both carry
# the same `Part of #P` (siblings of one decomposition) gets ` chain=#P` after
# its parent-pr. bin/stack-launch.sh launches those lines itself, stacked, with
# no model in between; every other STACKABLE line stays a triage offer.
#
# WAIT FOR THE PARENT TO MERGE (BH-5234). STACK_WAIT_PARENT_MERGE
# (bin/lib/stale-parent.sh sp_wait_mode; off|rollouts|all, default rollouts)
# holds a STACKABLE line back: `all` emits none, `rollouts` emits none for a
# rollout wave child (a body line `Rollout wave N of M:`, which fc_child_footer
# writes). Wave N+1 stacked on wave N is the shape whose parent kept being
# rewritten under it (#5010 under #5053). Such a child comes back as an ordinary
# UNBLOCKED line once its blocker closes. `off` is the pre-BH-5234 pass; an
# absent lib is `rollouts`.
#
# GitHub-Issues boards only (in-app boards have no Blocked-by convention yet).
# Fail-open: any failure prints nothing and exits 0 — the tick must never die
# on this. Never launches anything itself.
#
# Kill flags, one per class, both default ON:
#   STACKED_BUILDS=0 / flags/stacked-builds-off  drops the STACKABLE class.
#   DEP_VERIFY=0     / flags/dep-verify-off      drops the soft class: no verdict
#     is ever asked for, no comment is ever posted, and this script behaves
#     byte for byte as it did before W2-G.
#
# gh-rest: no-graphql
#
set -uo pipefail
PROJECT="${1:?usage: unblocked-children.sh <project>  (gate-diff text on stdin)}"
HARNESS="${HARNESS:-/root/harness}"
. "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$HARNESS")
MAX_LINES=25
# The tick that calls this sources global.env itself, but this script is also
# run by hand and by the fixtures, so it reads its own switch rather than
# trusting an inherited environment.
if [ -f "$HENV/global.env" ]; then set -a; # shellcheck disable=SC1091
  . "$HENV/global.env" 2>/dev/null; set +a; fi
STACK_OK=1
[ "${STACKED_BUILDS:-1}" = 0 ] && STACK_OK=0
[ -f "$HARNESS/flags/stacked-builds-off" ] && STACK_OK=0
# The soft class's switch lives in bin/lib/dep-verify-lib.sh, which is the one
# place three callers read it from. An absent lib (a scratch tree, an older box)
# is the flag being off, not a reason to guess.
DEP_OK=0
# shellcheck source=bin/lib/dep-verify-lib.sh
[ -r "$HARNESS/bin/lib/dep-verify-lib.sh" ] && . "$HARNESS/bin/lib/dep-verify-lib.sh" 2>/dev/null
command -v dep_verify_on >/dev/null 2>&1 && DEP_OK=$(dep_verify_on "$HARNESS")
[ -x "$HARNESS/bin/dep-verify.sh" ] || DEP_OK=0
DEP_DRY=0
command -v dep_verify_dry >/dev/null 2>&1 && DEP_DRY=$(dep_verify_dry "$HARNESS")
DEP_UNKNOWN=soft
command -v dep_unknown_mode >/dev/null 2>&1 && DEP_UNKNOWN=$(dep_unknown_mode "$HARNESS")
# shellcheck source=bin/lib/stale-parent.sh
[ -r "$HARNESS/bin/lib/stale-parent.sh" ] && . "$HARNESS/bin/lib/stale-parent.sh" 2>/dev/null
STACK_WAIT=rollouts
command -v sp_wait_mode >/dev/null 2>&1 && STACK_WAIT=$(sp_wait_mode "$PROJECT" 2>/dev/null)

repo="${GH_ISSUES_REPO:-}"
if [ -z "$repo" ]; then
  # Jira and Linear (bin/lib/trk-lane.sh): column 4 says `-` for them too, and
  # their tickets have no Blocked-by convention the harness writes yet (child
  # filing is wave 3 of #7920), so they get no line. An absent lib is today's path.
  TRK_LANE_KIND=""
  # shellcheck source=bin/lib/trk-lane.sh
  { . "$HARNESS/bin/lib/trk-lane.sh" 2>/dev/null || . "$(dirname "$0")/lib/trk-lane.sh" 2>/dev/null; } \
    && trk_lane_kind "$HARNESS" "$PROJECT"
  case "$TRK_LANE_KIND" in jira|linear) exit 0 ;; esac
  # The same mapping triage-gate.sh keeps; a fleet.conf project whose board
  # prefix is "-" is a GitHub-Issues board (load-project.sh onboards them so).
  # project-5 and project-6 are two such rows; their literal slugs are gone
  # (BH-4080), so fleet.conf column 2 answers for them like any other.
  bp=$("$HARNESS/bin/fleet-conf.sh" "$PROJECT" board_prefix 2>/dev/null || true)
  [ "$bp" = "-" ] && repo=$("$HARNESS/bin/fleet-conf.sh" "$PROJECT" repo 2>/dev/null || true)
fi
[ -n "$repo" ] || exit 0

DIFF=$(cat)
CLOSED=$(printf '%s\n' "$DIFF" | grep -oiE 'CHANGED [0-9]+ .*(state|status): *open *-> *closed' | grep -oE 'CHANGED [0-9]+' | awk '{print $2}' | sort -u)

# ── THE CLOSURES A BOARD DIFF CANNOT CARRY (2026-09-15) ──────────────────────
# The line above is the only trigger this pass has ever had, and it can only
# ever name an ai-build issue that moved since the last CONSUMED tick. Two real
# closures do not fit through it, and both cost a chain level every time:
#
#   * A DECOMPOSE PARENT. bin/run-decompose.sh parks the master unlabelled and
#     nothing ever closes it, so every ticket that says `Blocked-by: #<parent>`
#     waits forever — #671 behind a #670 whose children had all merged. Closing
#     it HERE, in the pass that is about to ask who was waiting on it, is what
#     releases its dependents in the SAME output.
#   * A CLOSURE THE WAKE SAW AND THE FINGERPRINT DID NOT. bin/wake-loop.sh
#     writes state/wake-closed-<project> beside the tick's keys; it is read
#     ONCE (bin/lib/revdep-lib.sh) and folded in here.
#
# Fail-open like everything else in this script: no lib, no script, or the kill
# flag, and this block contributes nothing and changes no other line.
# shellcheck source=bin/lib/revdep-lib.sh
[ -r "$HARNESS/bin/lib/revdep-lib.sh" ] && . "$HARNESS/bin/lib/revdep-lib.sh" 2>/dev/null
RD_ON=0
command -v revdep_on >/dev/null 2>&1 && RD_ON=$(revdep_on "$HARNESS")
if [ "$RD_ON" = 1 ]; then
  RD_PARENTS=""; RD_SHIPPED=""
  [ -x "$HARNESS/bin/decompose-parent-close.sh" ] && \
    RD_PARENTS=$("$HARNESS/bin/decompose-parent-close.sh" "$PROJECT" --cooled 2>/dev/null \
                   | grep -E '^[0-9]{1,9}$' | head -10)
  # REVDEP_TAKE=0 is bin/wake-loop.sh calling this script on the HUB: it passes
  # its closures on stdin already, and consuming the file there would eat the
  # copy the owning box's own tick is waiting for.
  [ "${REVDEP_TAKE:-1}" = 1 ] && RD_SHIPPED=$(revdep_take_closed "$HARNESS" "$PROJECT" 2>/dev/null)
  if [ -n "$RD_PARENTS$RD_SHIPPED" ]; then
    CLOSED=$(printf '%s\n%s\n%s\n' "$CLOSED" "$RD_PARENTS" "$RD_SHIPPED" \
               | grep -E '^[0-9]{1,9}$' | sort -un)
  fi
fi
# A closure is the UNBLOCKED class's trigger. STACKABLE has none: the fact it
# acts on is "the parent PR is open", which no board diff ever mentions, so with
# the class on the pass runs every tick. The soft class has none either — the
# fact IT acts on is "the child's pre-plan and the parent's PR disagree about
# whether this is a real dependency", which no diff mentions either. With both
# off this is the same early exit the script has always taken.
[ -n "$CLOSED" ] || [ "$STACK_OK" = 1 ] || [ "$DEP_OK" = 1 ] || exit 0

# Whichever token can SEE this repo (bin/lib/gh-repo-token.sh). The hub's
# default PAT 404s on example-org/project-5, which is the repo this whole lane is
# about — an empty issue list there would read exactly like "nothing is
# blocked". Absent lib (a scratch tree, an older box) = plain gh, as before.
# shellcheck source=bin/lib/gh-repo-token.sh
[ -r "$HARNESS/bin/lib/gh-repo-token.sh" ] && . "$HARNESS/bin/lib/gh-repo-token.sh" 2>/dev/null
command -v gh_repo_use_token >/dev/null 2>&1 && { gh_repo_use_token "$repo" || exit 0; }
# Then the App token, AFTER the probe so the probe keeps its invisible-repo alert.
# shellcheck source=bin/lib/gh-app-auth.sh
[ -r "$HARNESS/bin/lib/gh-app-auth.sh" ] && . "$HARNESS/bin/lib/gh-app-auth.sh" 2>/dev/null
command -v gh_auth_for >/dev/null 2>&1 && gh_auth_for "$repo" || true
# The REST contract the paper trail below posts through (#768): a comment that
# was refused returns non-zero, and the marker beside it is written only then.
# shellcheck source=bin/lib/gh-rest.sh
[ -r "$HARNESS/bin/lib/gh-rest.sh" ] && . "$HARNESS/bin/lib/gh-rest.sh"
# shellcheck source=bin/lib/gh-rest-list.sh
[ -r "$HARNESS/bin/lib/gh-rest-list.sh" ] && . "$HARNESS/bin/lib/gh-rest-list.sh"

# BH-1650: REST, upcased so the downstream "CLOSED"/"OPEN" comparisons hold; a
# failed page (403, 5xx) takes no action at all.
IL_T=$(mktemp) || exit 0
gh_rest_issue_list "$repo" all ai-build 100 > "$IL_T" 2>/dev/null || { rm -f "$IL_T"; exit 0; }
ALL=$(jq -c 'map({number, state:(.state|ascii_upcase), title, body})' "$IL_T" 2>/dev/null) || { rm -f "$IL_T"; exit 0; }
rm -f "$IL_T"
[ -n "$ALL" ] || exit 0
# The open harness PRs, once per tick: both "does a blocker already have a
# branch to stack on" and "does this child already have a PR" are answered from
# this one list. A failed list is not fatal — it only costs the STACKABLE class.
# The soft class reads it for the second question only: a child that already has
# a PR of its own is not a launch, so it is never judged and never commented on.
# Unconditional since the marker-gated release: the script only reaches this
# line when one of the three triggers is live, and all three now ask the same
# second question.
PRS=$(gh pr list -R "$repo" --state open --limit 100 --json number,url,title,headRefName,isDraft 2>/dev/null) || PRS="[]"   # gh-guard-allow: read not converted by BH-770.1; #770 tracks it
[ -n "$PRS" ] || PRS="[]"

ISSUES_FILE=$(mktemp) || exit 0
PRS_FILE=$(mktemp) || { rm -f "$ISSUES_FILE"; exit 0; }
# Where the dep pass writes what it decided: DEP_REC is every verdict (one line
# per child/blocker pair, for logs/<project>.log) and DEP_SOFT is the children
# that actually came out as launchable lines, which is the only set that earns a
# comment on a client-visible thread.
DEP_REC=$(mktemp) || { rm -f "$ISSUES_FILE" "$PRS_FILE"; exit 0; }
DEP_SOFT=$(mktemp) || { rm -f "$ISSUES_FILE" "$PRS_FILE" "$DEP_REC"; exit 0; }
DEP_TMP=$(mktemp -d) || { rm -f "$ISSUES_FILE" "$PRS_FILE" "$DEP_REC" "$DEP_SOFT"; exit 0; }
trap 'rm -rf "$ISSUES_FILE" "$PRS_FILE" "$DEP_REC" "$DEP_SOFT" "$DEP_TMP"' EXIT
printf '%s' "$ALL" > "$ISSUES_FILE"
printf '%s' "$PRS" > "$PRS_FILE"

# ONE --state all LIST FOR THE WHOLE PASS. bin/dep-verify.sh asks "does this
# blocker have a PR, and at which head sha" for every pair it judges, and left
# to itself it would ask GitHub once per pair — a 13-child wave with two
# blockers apiece is 26 identical requests against a PAT that has 5000 an hour
# (docs/BUILD-CONCURRENCY.md). The list above cannot be reused for it: that one
# is --state open, and a MERGED parent's changed files are the second-best file
# evidence and the only evidence once its branch is gone.
#
# WRITTEN ONLY ON SUCCESS, on purpose. An empty file means "we did not look" and
# each verdict falls back to asking for itself; an empty JSON ARRAY would mean
# "this blocker has no PR", which is a different claim and one a dead token must
# never be allowed to make.
DEP_PRS_FILE="$DEP_TMP/prs-all.json"
if [ "$DEP_OK" = 1 ]; then
  ALLPRS=$(gh pr list -R "$repo" --state all --limit 100 --json number,title,headRefName,headRefOid,state 2>/dev/null) || ALLPRS=""   # gh-guard-allow: read not converted by BH-770.1; #770 tracks it
  case "$ALLPRS" in \[*) printf '%s' "$ALLPRS" > "$DEP_PRS_FILE" ;; esac
fi
# The release marker's home is the dep cache dir, so state/dep-verify/<project>
# stays the one directory this lane writes per-child state into. The literal
# path is the fallback for a tree with no lib (the same absent-lib case that
# turns the soft class off).
MARKDIR="$HARNESS/state/dep-verify/$PROJECT"
command -v dep_cache_dir >/dev/null 2>&1 && MARKDIR=$(dep_cache_dir "$HARNESS" "$PROJECT")
REMIND_S="${UNBLOCKED_REMIND_S:-21600}"
case "$REMIND_S" in ''|*[!0-9]*) REMIND_S=21600 ;; esac

CLOSED="$CLOSED" MAX_LINES="$MAX_LINES" STACK_OK="$STACK_OK" \
DEP_OK="$DEP_OK" DEP_SH="$HARNESS/bin/dep-verify.sh" DEP_PROJECT="$PROJECT" \
DEP_REC="$DEP_REC" DEP_SOFT_FILE="$DEP_SOFT" DEP_TMP="$DEP_TMP" DEP_PRS_FILE="$DEP_PRS_FILE" \
DEP_REPO="$repo" DEP_MARK_DIR="$MARKDIR" DEP_REMIND_S="$REMIND_S" DEP_UNKNOWN_MODE="$DEP_UNKNOWN" \
STACK_WAIT="$STACK_WAIT" python3 - "$ISSUES_FILE" "$PRS_FILE" <<'PYEOF' 2>/dev/null
import json, os, re, subprocess, sys, time
try:
    with open(sys.argv[1]) as f:
        issues = json.load(f)
except Exception:
    sys.exit(0)
try:
    with open(sys.argv[2]) as f:
        prs = json.load(f)
    if not isinstance(prs, list):
        prs = []
except Exception:
    prs = []
closed_now = {int(n) for n in os.environ["CLOSED"].split() if n.isdigit()}
stack_ok = os.environ.get("STACK_OK") == "1"
dep_ok = os.environ.get("DEP_OK") == "1"
dep_sh = os.environ.get("DEP_SH", "")
dep_project = os.environ.get("DEP_PROJECT", "")
dep_tmp = os.environ.get("DEP_TMP", "")
# soft = an UNKNOWN verdict releases the child like SOFT would; hard = it holds
# the child like HARD (the pre-2026-09-16 behaviour). Read from the shell, which
# read it from bin/lib/dep-verify-lib.sh, so all three callers agree.
unknown_soft = os.environ.get("DEP_UNKNOWN_MODE", "soft") != "hard"
# BH-5234: off | rollouts | all, read by the shell through sp_wait_mode.
stack_wait = os.environ.get("STACK_WAIT", "rollouts")
rollout_re = re.compile(r"^Rollout wave \d+ of \d+:", re.MULTILINE)
repo = os.environ.get("DEP_REPO", "")
mark_dir = os.environ.get("DEP_MARK_DIR", "")
try:
    remind_s = int(os.environ.get("DEP_REMIND_S", "21600"))
except Exception:
    remind_s = 21600
# At most this many blockers are looked up by number in one pass. The set is
# normally tiny (the decomposed parents the size gate un-labelled), and a body
# that names a hundred numbers must not turn one tick into a hundred requests.
MAX_FETCH = 30
state = {int(i["number"]): str(i.get("state", "")).upper() for i in issues if isinstance(i, dict) and "number" in i}
# "Blocked-by: #331", "Blocked-by #331, #332", "blocked-by: TK-331 / #331" — take
# every #N on a line that starts (after markdown noise) with Blocked-by.
line_re = re.compile(r"^[\s>*_\-#]*blocked[- ]by\b(.*)$", re.IGNORECASE | re.MULTILINE)
num_re = re.compile(r"#(\d+)")
# A decompose child's body carries `Part of #<master>` (bin/run-decompose.sh);
# two issues naming the same master are siblings of one decomposition (BH-3684).
part_re = re.compile(r"^[\s>*_\-]*Part of #(\d+)\s*$", re.IGNORECASE | re.MULTILINE)
by_num = {int(i["number"]): i for i in issues if isinstance(i, dict) and "number" in i}


def part_of(issue):
    m = part_re.search((issue or {}).get("body") or "")
    return int(m.group(1)) if m else None


def harness_pr_for(n):
    """The OPEN, non-draft harness PR built for issue <n>, or None.

    The two names run-build.sh gives its work: the branch it cuts
    (ticket/<key-lowercased>, plus the -r<n> retry suffix) and the PR title it
    opens (<KEY>: <subject>). Matching on the ISSUE NUMBER rather than the key
    keeps this free of the per-project key prefix, which this script has never
    had to know.
    """
    br_re = re.compile(r"^ticket/[a-z0-9]+-%d(-r\d+)?$" % n, re.IGNORECASE)
    ti_re = re.compile(r"^[A-Za-z]+-%d:" % n)
    for p in prs:
        if not isinstance(p, dict) or p.get("isDraft"):
            continue
        if br_re.match(str(p.get("headRefName", ""))) or ti_re.match(str(p.get("title", ""))):
            return p
    return None


def dep_verify(child, blocker, body):
    """bin/dep-verify.sh's verdict for one (child, blocker) pair.

    The child's issue body rides in on a file because THIS script already
    fetched it: making the verdict re-read it would be one more issue read per
    blocker for a fact already in memory, which is the token rule this fleet
    runs on. Anything that is not a clean HARD/SOFT/UNKNOWN answer — a missing
    script, a timeout, a crash — reads as UNKNOWN, and DEP_UNKNOWN_MODE decides
    whether that releases the child (soft, the default) or holds it (hard).
    """
    bf = os.path.join(dep_tmp, "body-%d" % child)
    if not os.path.exists(bf):
        try:
            with open(bf, "w") as f:
                f.write(body or "")
        except Exception:
            return ("UNKNOWN", "could not stage the issue body")
    env = dict(os.environ)
    env["DEP_CHILD_BODY_FILE"] = bf
    try:
        out = subprocess.run([dep_sh, dep_project, str(child), str(blocker)],
                             stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                             timeout=120, env=env).stdout.decode("utf-8", "replace").strip()
    except Exception:
        return ("UNKNOWN", "dep-verify did not answer")
    parts = out.split(" ", 1)
    if not parts or parts[0] not in ("HARD", "SOFT", "UNKNOWN"):
        return ("UNKNOWN", "dep-verify did not answer")
    return (parts[0], parts[1] if len(parts) > 1 else "no reason given")


def fetch_state(n):
    """One blocker's state, read by NUMBER rather than from the labelled list.

    The list this pass works from is `--label ai-build`, and the size gate
    STRIPS that label from a parent it decomposed — so an open parent simply
    was not in it, and `state.get(b, "CLOSED")` called it closed. Asking for it
    by number is the only way to tell "closed" from "not in this list". An
    answer that is not OPEN/CLOSED is no answer: the caller then leaves the
    child alone rather than guessing at its blocker.
    """
    if not repo:
        return ""
    try:
        out = subprocess.run(["gh", "issue", "view", str(n), "-R", repo,
                              "--json", "number,state,title"],
                             stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                             timeout=60).stdout
        d = json.loads(out.decode("utf-8", "replace"))
    except Exception:
        return ""
    s = str(d.get("state", "")).upper() if isinstance(d, dict) else ""
    return s if s in ("OPEN", "CLOSED") else ""


def blocker_state(n):
    if n in closed_now:
        return "CLOSED"        # the diff watched it happen this tick
    return state.get(n) or "UNKNOWN"


def released_recently(n):
    """rc True when this child was already offered as released inside the window.

    The diff-driven line fires on an EVENT and needs no such gate. The line
    below it fires on a STATE — "every blocker is closed" stays true forever —
    so without a marker it would be re-emitted every tick until the build
    starts. A window rather than a one-shot: a child nobody launched is offered
    again in six hours, which is the difference between rate-limiting a line
    and dropping a ticket.
    """
    if not mark_dir:
        return False
    try:
        return (time.time() - os.path.getmtime(os.path.join(mark_dir, "%d.unblocked" % n))) < remind_s
    except Exception:
        return False


# The blocked children, and the blockers whose state the labelled list cannot
# answer for. Collected in one pass so the lookups are batched and bounded.
blocked = []
for i in sorted(issues, key=lambda x: int(x.get("number", 0))):
    if not isinstance(i, dict) or state.get(int(i["number"])) != "OPEN":
        continue
    bs = set()
    for m in line_re.finditer(i.get("body") or ""):
        bs.update(int(n) for n in num_re.findall(m.group(1)))
    if bs:
        blocked.append((int(i["number"]), i, bs))
unseen = sorted({b for _, _, bs in blocked for b in bs} - set(state) - closed_now)
for b in unseen[:MAX_FETCH]:
    s = fetch_state(b)
    if s:
        state[b] = s

unblocked, softlines, stackable = [], [], []
records, remind = [], []
for num, i, blockers in blocked:
    # A blocker nobody could read is not a blocker that closed. Skipping the
    # child costs a wait; assuming costs a build on a base that is not there.
    if any(blocker_state(b) == "UNKNOWN" for b in blockers):
        continue
    still_open = sorted(b for b in blockers if blocker_state(b) == "OPEN")
    # THE CHILD'S OWN PR IS THE FIRST QUESTION FOR EVERY CLASS: a child that is
    # already built or building is not a launch, so it is neither judged (which
    # costs GitHub calls) nor commented on (which costs a client's attention).
    mine = harness_pr_for(num)
    if not still_open:
        fired = sorted(blockers & closed_now)
        if fired:
            unblocked.append(
                f'board issues: UNBLOCKED {num} "{i.get("title", "")}" '
                f'(Blocked-by #{", #".join(str(b) for b in fired)} is now CLOSED and no other blocker is open — '
                f'fetch it and launch per the queue rules if no PR or build already covers it)'
            )
            continue
        # Nothing in THIS diff released it — and for a de-labelled parent
        # nothing ever will, because the fingerprint the diff is computed from
        # only carries ai-build issues. The state IS the release.
        if mine or released_recently(num):
            continue
        line = (
            f'board issues: UNBLOCKED {num} "{i.get("title", "")}" '
            f'(every blocker it names — #{", #".join(str(b) for b in sorted(blockers))} — is CLOSED, '
            f'and no board diff ever carried that closure: a decomposed parent loses the ai-build label, '
            f'so this line is the release — fetch it and launch per the queue rules if no PR or build already covers it)'
        )
        unblocked.append(line)
        remind.append((line, num))
        continue
    if dep_ok and not mine:
        verdicts = [(b,) + dep_verify(num, b, i.get("body") or "") for b in still_open]
        records.extend((num,) + v for v in verdicts)
        released = {"SOFT", "UNKNOWN"} if unknown_soft else {"SOFT"}
        if all(v[1] in released for v in verdicts):
            names = ", ".join("#%d" % v[0] for v in verdicts)
            why = " | ".join(v[2] for v in verdicts)
            if all(v[1] == "SOFT" for v in verdicts):
                kind = "SOFT"
                line = (
                    f'board issues: UNBLOCKED {num} "{i.get("title", "")}" '
                    f'(dep-verified soft: {names} — those blockers are still open, but this slice\'s planned files '
                    f'are disjoint from theirs and its plan declares the dependency ordering-only, so it builds on '
                    f'MAIN now; same queue rules as any UNBLOCKED line, if no PR or build already covers it)')
            else:
                # At least one pair had no evidence either way. Say so in the
                # line: the tick that launches it must not read "verified".
                kind = "UNKNOWN"
                line = (
                    f'board issues: UNBLOCKED {num} "{i.get("title", "")}" '
                    f'(dep-unverified, released: {names} — those blockers are still open and the dependency could '
                    f'not be verified yet ({why}); DEP_UNKNOWN_MODE=soft releases it to build on MAIN now and the '
                    f'conductor\'s self-rebase resolves any real overlap at merge time; same queue rules as any '
                    f'UNBLOCKED line, if no PR or build already covers it)')
            softlines.append((line, num, names, why, kind))
            continue
    if not stack_ok:
        continue
    # EXACTLY ONE still-open blocker: a child can only be cut from one base
    # branch, so two live parents stay a wait, not a stack.
    if len(still_open) != 1:
        continue
    if mine:
        continue  # this child is already built or building — nothing to launch
    parent = harness_pr_for(still_open[0])
    if not parent:
        continue
    # BH-5234: wait for the parent to merge instead of stacking on it.
    if stack_wait == "all" or (stack_wait != "off" and rollout_re.search(i.get("body") or "")):
        continue
    # The blocker is looked up in memory only: one fetched by number (a
    # de-labelled parent) has no body here, so its child keeps the plain line.
    mp, bp = part_of(i), part_of(by_num.get(still_open[0]))
    chain = f' chain=#{mp}' if mp is not None and mp == bp else ''
    stackable.append(
        f'board issues: STACKABLE {num} "{i.get("title", "")}" '
        f'base={parent.get("headRefName", "")} parent-pr={parent.get("url", "")}{chain} '
        f'(Blocked-by #{still_open[0]} is still open but its PR is open too — launchable NOW on top of that branch, '
        f'same queue rules as UNBLOCKED, if no PR or build already covers it)'
    )

out = (unblocked + [x[0] for x in softlines] + stackable)[: int(os.environ["MAX_LINES"])]
print("\n".join(out))

# The release markers, and only for lines that SURVIVED the MAX_LINES trim —
# the same rule the thread comments follow below: a line that was not emitted
# is not an offer, so it must not silence the tick that would have made one.
for line, n in remind:
    if line not in out or not mark_dir:
        continue
    try:
        os.makedirs(mark_dir, exist_ok=True)
        open(os.path.join(mark_dir, "%d.unblocked" % n), "w").close()
    except Exception:
        pass

# What the caller logs and comments on. Every verdict is recorded, because
# "#674 was judged HARD against #671 and here is why" is the line an operator
# needs when a wave stays narrow. Only the soft children that SURVIVED the
# MAX_LINES trim are offered for a comment: a line that was not emitted is not a
# launch, and a thread must never carry a note about a build nobody started.
try:
    with open(os.environ["DEP_REC"], "w") as f:
        for child, blocker, verdict, why in records:
            f.write("%d\t%d\t%s\t%s\n" % (child, blocker, verdict, why.replace("\t", " ")))
    with open(os.environ["DEP_SOFT_FILE"], "w") as f:
        for line, num, names, why, kind in softlines:
            if line in out:
                f.write("%d\t%s\t%s\t%s\n" % (num, kind, names, why.replace("\t", " ")))
except Exception:
    pass
PYEOF
PYRC=$?
[ "$PYRC" = 0 ] || exit 0

# >>> the dep pass's paper trail (W2-G)
# THE LOG LINES ARE THE DIAGNOSTIC, and they are written whether or not anything
# was widened: a wave that stays five levels deep because every child came back
# UNKNOWN looks, from outside, exactly like a wave nobody checked. docs/EVENTS.md
# carries both names.
if [ "$DEP_OK" = 1 ] && [ -s "$DEP_REC" ]; then
  mkdir -p "$HARNESS/logs" 2>/dev/null
  TS=$(date -u '+%Y-%m-%d %H:%M:%SZ')
  while IFS=$'\t' read -r C B V W; do
    [ -n "${C:-}" ] || continue
    case "$V" in
      SOFT)    printf '%s [%s] DEP_SOFT %s vs %s — %s\n' "$TS" "$PROJECT" "$C" "$B" "$W" ;;
      HARD)    printf '%s [%s] DEP_HARD %s vs %s — %s\n' "$TS" "$PROJECT" "$C" "$B" "$W" ;;
      *) if [ "$DEP_UNKNOWN" = soft ]; then
           printf '%s [%s] DEP_SOFT %s vs %s — UNKNOWN, released (DEP_UNKNOWN_MODE=soft): %s\n' "$TS" "$PROJECT" "$C" "$B" "$W"
         else
           printf '%s [%s] DEP_HARD %s vs %s — UNKNOWN, treated as hard: %s\n' "$TS" "$PROJECT" "$C" "$B" "$W"
         fi ;;
    esac
  done < "$DEP_REC" >> "$HARNESS/logs/$PROJECT.log" 2>/dev/null
fi

# ONE COMMENT PER CHILD, EVER. The marker beside the verdict cache is what makes
# that true across ticks — the soft verdict itself is cached and stable, so
# without it every tick until the build starts would post the same paragraph
# again. Dry run writes nothing and says nothing.
if [ "$DEP_OK" = 1 ] && [ "$DEP_DRY" != 1 ] && [ -s "$DEP_SOFT" ]; then
  mkdir -p "$MARKDIR" 2>/dev/null
  while IFS=$'\t' read -r C KIND NAMES WHY; do
    [ -n "${C:-}" ] || continue
    [ -e "$MARKDIR/$C.commented" ] && continue
    if [ "$KIND" = SOFT ]; then
      BODY="Building this now, against main, instead of waiting for $NAMES.

We checked the dependency rather than taking it on trust: this ticket's planned files do not touch anything those tickets change, and its plan says the link is ordering preference, not code ($WHY). If that is wrong, say so here and we will rebase it behind them. To pin a real code dependency so nothing second-guesses it, write \`Blocked-by: $NAMES (hard)\` in the issue body."
    else
      # Released on no evidence, and the thread says exactly that — a client
      # reading "we checked" about a check that could not run is a lie.
      BODY="Building this now, against main, instead of waiting for $NAMES.

We could not verify the dependency yet ($WHY), and this harness is set to build rather than wait in that case: if this ticket turns out to need code from those tickets, the merge step rebases it behind them. If you already know it does, say so here and we will hold it. To pin a real code dependency so nothing second-guesses it, write \`Blocked-by: $NAMES (hard)\` in the issue body."
    fi
    # The marker follows the POST (BH-781), never the attempt: a rate-limited
    # tick that marked anyway would silently drop the one paragraph telling the
    # client why their ticket was released. The body goes by FILE, not argv.
    BF=$(mktemp "${TMPDIR:-/tmp}/dep-note.XXXXXX") || continue
    printf '%s\n' "$BODY" > "$BF"
    if gh_rest_comment "$repo" "$C" "$BF"; then
      : > "$MARKDIR/$C.commented" 2>/dev/null
    fi
    rm -f "$BF"
  done < "$DEP_SOFT"
fi
# <<< the dep pass's paper trail
command -v gh_auth_reset >/dev/null 2>&1 && gh_auth_reset
exit 0
