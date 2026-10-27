#!/bin/bash
# bin/launch-fastpath.sh <project> <key> [<key>...]        (BH-482.1 — the real launcher)
#
# THE CONTRACT (BH-482.0 wrote it as a stub; this file keeps every line of it):
#   argv     <project> then one or more keys; a key is a bare issue number or <PFX>-<n>.
#   exit 0   iff EVERY key launched.   exit 1 otherwise (zero keys included).
#   stdout   the DECLINED keys, one per line, nothing else.
#   log      one line per key appended to $HARNESS/logs/<project>.log:
#              FASTPATH <KEY> (issue #n) — launched
#              FASTPATH-DECLINED <KEY> :: <first failing condition>
#   never    writes to GitHub, comments, or merges.
#   alert    one ALERTS line per (hotfix KEY, deciding line) when a ticket with
#            the hotfix label is declined for a HOLD (BH-6297). Never changes
#            the decline, stdout or the exit code.
#   mode     dispatch mode hotfix-only (bin/lib/dispatch-mode.sh, BH-6350): a
#            key with no hotfix label and not on the allow-list is declined
#            on stdout with no per-key line; ONE line per run names them:
#              DISPATCH-MODE hotfix-only: <k> key(s) wait (<KEYS>); allow-list: <n,n|none>
#   hotfix   an issue with the hotfix label skips condition 11 (the spec
#            headings): a hotfix body is an incident note (BH-7117).
#   kill     flags/fastpath-off on the box declines everything.
#   stack    FASTPATH_STACK_BASE=<branch> FASTPATH_STACK_PARENT=<n>
#            [FASTPATH_STACK_PARENT_PR=<url>], exactly one key (BH-3684,
#            bin/stack-launch.sh): the named parent is accepted as the key's
#            one open blocker without asking dep-verify.sh, and the build is
#            spawned with STACK_BASE / STACK_PARENT_PR set. Same argv. The log
#            line gains ` stacked on <base> (parent #<n>)`.
#   HARNESS  ${HARNESS:-/root/harness}, the same resolution as bin/orphan-reconcile.sh.
#
# WHAT IT IS FOR. A wake that names a ticket today buys a triage session, and a
# triage session is minutes and a model call before the first line of the build
# is written. Most of those sessions re-derive the same answer: this ticket is
# labelled, unheld, unblocked, unowned — build it. This script answers that
# question deterministically, with no LLM anywhere in the run, and launches the
# SOP line itself. Anything it is not certain about it DECLINES, and the caller
# falls through to the triage tick that would have run anyway. A decline costs
# one log line; a wrong launch costs a duplicate build.
#
# The conditions are evaluated IN ORDER and stop at the first failure, so the
# reason named is the FIRST thing that was wrong and is true in exactly that
# state (D13). Global gates 0-7 are read once per run; 8-18 are per key, and
# 16-18 — the three LOCAL reads a concurrent run can change under us — are read
# a second time inside the launch lock, which is what "around eligibility+launch"
# buys: one launch per key even when two runs decide it at the same moment.
#
# FAIL CLOSED, like bin/orphan-reconcile.sh and for the same reason: a gh list
# that fails, a ledger that cannot be reached, a blocker whose state cannot be
# read — every one of those means "we do not know whether this ticket is being
# worked", and the honest answer to that is to decline and let triage look.
#
# EVERY GITHUB READ IS REST, through bin/lib/gh-rest.sh (BH-1163). The CLI's
# `gh issue view` / `gh pr list` / `gh issue list` speak GraphQL, they share one
# rate-limit bucket with every other lane on this box, and on 2026-09-18 (#768)
# a rate-limited one answered an EMPTY STRING that a decision path read as
# "no such thing". The library answers rc 0 (act on the body), rc 44 (absent) or
# rc 75 (GitHub did not answer), and every read below names which of the three
# it got. The marker line above `set -uo pipefail` is what
# tests/gh-no-graphql-decision-guard-test.sh holds this file to from here on.
#
# Bounds (D21): at most 50 keys per run (the 51st is DECLINED with a reason,
# never silently dropped), at most 5 REST reads per key — the issue, its thread
# (only when the issue's own comment count is > 0), the one lazy ai-build state
# list (once per run, only when some body carries a Blocked-by line) and at most
# 2 per-number blocker reads — plus one PR list and two ledger reads per run.
# The dep-verify.sh calls spend their own cached budget (state/dep-verify/),
# which is that script's bound, not this one's.
#
# GitHub-Issues boards only (board_prefix "-" in fleet.conf): the in-app boards
# have no ai-build label and no Blocked-by convention.
# gh-rest: no-graphql
set -uo pipefail
# BH-1138: no __pycache__ next to bin/*.py. This script runs python3 on a
# scratch module; the tripwire (tests/pycache-untracked.bh-1138-test.sh)
# requires every python caller under bin/ to carry the export in scope.
export PYTHONDONTWRITEBYTECODE=1
HARNESS="${HARNESS:-/root/harness}"
# shellcheck disable=SC1091
. "$HARNESS/bin/lib/lane-switch.sh" 2>/dev/null || true
command -v ls_isolated >/dev/null 2>&1 || ls_isolated() { [ -f "$HARNESS/flags/$2" ]; }
project="${1:-}"; shift || true
[ -n "$project" ] && [ $# -gt 0 ] || exit 1
KEYS=("$@")

# THE PROJECT NAME IS VALIDATED BEFORE THE FIRST LOG WRITE. It is interpolated
# straight into $HARNESS/logs/$project.log two lines down, so a name carrying a
# path separator writes outside logs/ before any condition has run. Today the
# only callers are internal (bin/wake-loop.sh passes a fleet.conf name through
# printf %q), and this is what makes that a fact about the script instead of a
# fact about its callers. The keys are still echoed back as declined — the
# caller can diff its own input — but nothing is logged, because the log path is
# precisely what is not trustworthy here.
case "$project" in
  *[!A-Za-z0-9._-]*) printf '%s\n' "${KEYS[@]}"; exit 1 ;;
esac

LOG="$HARNESS/logs/$project.log"
mkdir -p "$HARNESS/logs" "$HARNESS/locks" "$HARNESS/state" 2>/dev/null
log() { echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') [$project] $*" >> "$LOG"; }
# The key is echoed back AS GIVEN, so a caller can diff its own input; the log
# line carries the canonical KEY once there is one (an unparseable key has none).
decline() { log "FASTPATH-DECLINED $1 :: $2"; printf '%s\n' "$1"; declined=$((declined+1)); }
decline_all() { local r="$1" k; for k in "${KEYS[@]}"; do decline "$k" "$r"; done; exit 1; }
declined=0

# THE TWO WAYS A REST READ FAILS ARE DIFFERENT SENTENCES (D10, BH-1163). 44 is
# GitHub answering "there is no such thing", which is a FACT this lane acts on;
# 75 is GitHub not answering at all, which is an outage somebody has to see, so
# it costs one ALERTS line and nothing else. Both decline the key — this lane
# declines on anything it is not certain about — but a log full of
# `absent (HTTP 404)` and a log full of `unverifiable (HTTP 429 rate-limit)`
# are two different mornings.
#
# Called as a plain command AFTER a read that ran as `helper > file`, never
# inside the read's own `$( )`: GH_REST_STATUS is set in the shell that calls a
# helper, and a status read out of a dead subshell is the BH-781 bug where every
# alert said "HTTP 000" for a 403 the library had classified correctly.
rest_reason() { # rest_reason <what> <rc> -> the decline reason on stdout
  case "${2:-}" in
    44) printf '%s absent (HTTP 404)\n' "$1" ;;
    *)  printf '%s unverifiable (HTTP %s%s)\n' "$1" "${GH_REST_STATUS:-000}" \
          "${GH_REST_REASON:+ $GH_REST_REASON}"
        command -v gh_rest_alert >/dev/null 2>&1 \
          && gh_rest_alert "$project" launch-fastpath "$1" || true ;;
  esac
}
# The two reads that do NOT decline a key on their own — the ai-build state list
# and the per-number blocker read. Both fail INTO "this blocker is open", which
# is the fail-closed direction this script has always taken there (an open
# blocker goes to dep-verify.sh, and an unverified chain belongs to triage). A
# GitHub that stopped answering is still never a quiet tick: it says so on the
# project's own log, and a 75 wakes somebody up.
rest_log_open() { # rest_log_open <what> <rc> <what reads OPEN>
  case "${2:-}" in
    44) log "fastpath: $1 answered HTTP 404 — $3" ;;
    *)  log "fastpath: $1 unverifiable (HTTP ${GH_REST_STATUS:-000}${GH_REST_REASON:+ $GH_REST_REASON}) — $3"
        command -v gh_rest_alert >/dev/null 2>&1 \
          && gh_rest_alert "$project" launch-fastpath "$1" || true ;;
  esac
}

# Its own switch read, not an inherited environment: this runs from a wake
# receiver, by hand and from the fixtures (bin/orphan-reconcile.sh:85).
# The env dir is resolved through bin/lib/env-path.sh (/etc/harness/env on a
# ported box, $HARNESS/env otherwise), never assumed. The fallback keeps a
# checkout without the lib on the old path rather than reading nothing.
# shellcheck disable=SC1091
. "$HARNESS/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }
HENV=$(harness_env_dir "$HARNESS")
if [ -f "$HENV/global.env" ]; then set -a
  # shellcheck disable=SC1091
  . "$HENV/global.env" 2>/dev/null; set +a; fi

GRACE_MIN="${ORPHAN_GRACE_MIN:-12}"
case "$GRACE_MIN" in ''|*[!0-9]*) GRACE_MIN=12 ;; esac
MAX_KEYS=50            # the run cap; over it a key is declined, never dropped
BLOCKER_FETCH_MAX=2    # per-number blocker views per key; the rest read OPEN

command -v jq      >/dev/null 2>&1 || decline_all "jq missing"
command -v python3 >/dev/null 2>&1 || decline_all "python3 missing"

# ---- 0. the kill switch (BH-2435: the settings row, then the file) ----------
ls_isolated lane_switch fastpath-off file && decline_all "fastpath off"

# ---- 0b. stack mode (BH-3684) -----------------------------------------------
# Validated before any read: a malformed stack request is a caller bug, and a
# half-set one must never fall through to a plain launch on the project base.
FP_SB="${FASTPATH_STACK_BASE:-}"; FP_SP="${FASTPATH_STACK_PARENT:-}"; FP_SPR="${FASTPATH_STACK_PARENT_PR:-}"
if [ -n "$FP_SB$FP_SP" ]; then
  [ -n "$FP_SB" ] && [ -n "$FP_SP" ] || decline_all "stack mode: base and parent are both required"
  case "$FP_SP" in *[!0-9]*) decline_all "stack mode: parent '$FP_SP' is not an issue number" ;; esac
  [[ "$FP_SB" =~ ^[A-Za-z0-9._/-]+$ ]] && [[ "$FP_SB" != *..* ]] || decline_all "stack mode: unsafe base branch"
  [ "${#KEYS[@]}" = 1 ] || decline_all "stack mode: exactly one key per run"
  { [ "${STACKED_BUILDS:-1}" = 0 ] || ls_isolated lane_switch stacked-builds-off file; } && decline_all "stacked builds off"
fi

# ---- 1. the board has to be GitHub Issues -----------------------------------
# Column 4 says `-` for a Jira or Linear project too (bin/lib/trk-lane.sh asks
# tracker_kind). This path launches GitHub issues only; building a Jira or
# Linear ticket is wave 3 of #7920.
TRK_LANE_KIND=""
# shellcheck source=bin/lib/trk-lane.sh
{ . "$HARNESS/bin/lib/trk-lane.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/trk-lane.sh" 2>/dev/null; } \
  && trk_lane_kind "$HARNESS" "$project"
case "$TRK_LANE_KIND" in jira|linear) decline_all "not a GitHub-Issues board ($TRK_LANE_KIND)" ;; esac
BP=$("$HARNESS/bin/fleet-conf.sh" "$project" board_prefix 2>/dev/null || true)
[ "$BP" = "-" ] || decline_all "not a GitHub-Issues board"
REPO=$("$HARNESS/bin/fleet-conf.sh" "$project" repo 2>/dev/null || true)
[ -n "$REPO" ] && [ "$REPO" != "-" ] || decline_all "not a GitHub-Issues board"
# Every gh read below runs on the repo's App installation token when this box
# mints one; an unarmed box returns 1 here without a fork and reads on the PAT
# exactly as before (bin/lib/gh-app-auth.sh).
# shellcheck disable=SC1091
. "$HARNESS/bin/lib/gh-app-auth.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/gh-app-auth.sh" 2>/dev/null || true
# The builds/ archive index (BH-7437): check 17 counts an archived build too.
. "$HARNESS/bin/lib/build-archive.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/build-archive.sh" 2>/dev/null || true
command -v gh_auth_for >/dev/null 2>&1 && { gh_auth_for "$REPO" || true; }

# THE REST CONTRACT every GitHub read below goes through (BH-1163): rc 0 act on
# the body, rc 44 the thing is ABSENT, rc 75 GitHub did not answer. NOT optional,
# unlike the libs around it: a launcher whose readers are undefined functions
# answers rc 127 on every one of them, and 127 is neither 44 nor 75. Rather than
# let a box mid-sync read that as an empty board and a ticket nobody owns — which
# is the one shape that ends in a duplicate build — every key is declined and the
# reason says which file is missing.
# shellcheck source=bin/lib/gh-rest-list.sh
[ -r "$HARNESS/bin/lib/gh-rest-list.sh" ] && . "$HARNESS/bin/lib/gh-rest-list.sh" 2>/dev/null \
  || . "$(dirname "${BASH_SOURCE[0]}")/lib/gh-rest-list.sh" 2>/dev/null || true
if ! command -v gh_rest >/dev/null 2>&1 \
   || ! command -v gh_rest_pr_list_all >/dev/null 2>&1 \
   || ! command -v gh_rest_issue_list >/dev/null 2>&1 \
   || ! command -v gh_rest_issue_comments >/dev/null 2>&1; then
  decline_all "gh-rest lib missing"
fi

# ---- 2. paused (the bin/run-triage.sh:83-84 pair) ---------------------------
# flag_active decides (BH-4153: the paused-<project> row, DB-first, the cache on
# an outage, ON when nothing can be read). No client: the file, as before.
# shellcheck source=/dev/null
[ -r "$HARNESS/bin/jobs-client.sh" ] && . "$HARNESS/bin/jobs-client.sh" 2>/dev/null
if command -v flag_active >/dev/null 2>&1; then
  flag_active "paused-$project" >/dev/null 2>&1 && decline_all "project paused"
else
  [ -f "$HARNESS/flags/paused-$project" ] && decline_all "project paused"
fi

# ---- 2b. the dispatch mode (BH-6350) ----------------------------------------
# Read once per run. In hotfix-only, condition 15c below holds a key that has no
# hotfix label and is not on the row's allow-list. The lib absent: normal.
DM_MODE=normal; DM_ALLOW=""; DM_WAIT=""; DM_UNREADABLE=0
# shellcheck source=bin/lib/dispatch-mode.sh
[ -r "$HARNESS/bin/lib/dispatch-mode.sh" ] && . "$HARNESS/bin/lib/dispatch-mode.sh" 2>/dev/null
command -v dm_read >/dev/null 2>&1 && dm_read "$project"
[ "$DM_UNREADABLE" = 1 ] && log "dispatch mode unreadable, reading normal"

# ---- 3. the key prefix ------------------------------------------------------
# shellcheck source=bin/lib/preplan-lib.sh
[ -r "$HARNESS/bin/lib/preplan-lib.sh" ] && . "$HARNESS/bin/lib/preplan-lib.sh" 2>/dev/null
command -v preplan_key_prefix >/dev/null 2>&1 || decline_all "no key prefix"
PFX=$(preplan_key_prefix "$HARNESS" "$project" 2>/dev/null) || PFX=""
[ -n "$PFX" ] || decline_all "no key prefix"

# ---- 4. a token that can SEE the repo ---------------------------------------
# shellcheck source=bin/lib/gh-repo-token.sh
[ -r "$HARNESS/bin/lib/gh-repo-token.sh" ] && . "$HARNESS/bin/lib/gh-repo-token.sh" 2>/dev/null
command -v gh_repo_use_token >/dev/null 2>&1 || decline_all "repo invisible to every token"
gh_repo_use_token "$REPO" || decline_all "repo invisible to every token"

# NO CHILD OF A LANE CARRIES THAT LANE'S LOCK (BH-651, bin/lib/lock-hygiene.sh).
# The build this script spawns outlives the wake that rang it, and a flock lives
# on the open file description — so a build that inherited fd 8 or fd 9 would
# hold the caller's tick lock for its whole life. The fallback keeps a box that
# has not received the lib yet closing the same fds, exactly as
# bin/orphan-reconcile.sh does it.
# shellcheck source=bin/lib/lock-hygiene.sh
[ -r "$HARNESS/bin/lib/lock-hygiene.sh" ] && . "$HARNESS/bin/lib/lock-hygiene.sh" 2>/dev/null
if ! command -v lock_spawn_unheld >/dev/null 2>&1; then
  lock_spawn_unheld() { [ $# -gt 0 ] || return 0; ( exec 8>&- 9>&-; exec "$@" ) & }
fi

# THE RUN BEAT (BH-2755): a launched key buys no triage tick, so without this
# it leaves no row in the console's runs table. Strict, and a beat the console
# did not take is one ALERTS line per box per day (bin/lib/run-beat.sh). The
# fallback keeps a box without the lib sending the beat as it always could.
# shellcheck source=bin/lib/run-beat.sh
[ -r "$HARNESS/bin/lib/run-beat.sh" ] && . "$HARNESS/bin/lib/run-beat.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/run-beat.sh" 2>/dev/null || true
command -v run_beat >/dev/null 2>&1 || run_beat() { "$HARNESS/bin/beat.sh" "$1" >/dev/null 2>&1 || true; }

# THE HOLD VOCABULARY, shared with bin/orphan-reconcile.sh and
# bin/blocked-resolver.sh (bin/lib/hold.sh): the same three regexes, exported
# into the classifier's environment below, so "what counts as a hold" cannot
# drift between the lane that re-enqueues builds and the lane that launches them
# without buying a session (BH-408). A box mid-sync without the lib falls back to
# the literals this script has always used — see the os.environ.get defaults,
# which carry NO lift vocabulary, so an unsynced box holds exactly as it did.
# shellcheck source=bin/lib/hold.sh
[ -r "$HARNESS/bin/lib/hold.sh" ] && . "$HARNESS/bin/lib/hold.sh" 2>/dev/null
# The hotfix label reader, for the one alert a HOLD on a hotfix costs (BH-6297).
# Absent, no ticket reads as a hotfix and nothing alerts.
# shellcheck source=bin/lib/hotfix-lib.sh
[ -r "$HARNESS/bin/lib/hotfix-lib.sh" ] && . "$HARNESS/bin/lib/hotfix-lib.sh" 2>/dev/null

# ---- 5. the GitHub API budget -----------------------------------------------
# rc 0 low (decline), 1 healthy, 2 unknown — unknown proceeds, exactly as
# bin/orphan-reconcile.sh reads it.
# shellcheck source=bin/lib/gh-budget.sh
[ -r "$HARNESS/bin/lib/gh-budget.sh" ] && . "$HARNESS/bin/lib/gh-budget.sh" 2>/dev/null
if command -v gh_budget_low >/dev/null 2>&1 && gh_budget_low launch-fastpath; then
  decline_all "gh budget low"
fi

TD=$(mktemp -d) || exit 1
trap 'rm -rf "$TD"' EXIT

# ---- 6. the two ledger reads (FAIL CLOSED) ----------------------------------
# The ledger is the only thing that knows a build is already running on a pool
# machine two hops away. A ledger we cannot read is a ticket whose owner we
# cannot name, and that is a decline, never a launch.
if ! command -v _jobs_req >/dev/null 2>&1 || ! command -v queue_list >/dev/null 2>&1; then
  decline_all "ledger unreachable"
fi
if ! JROWS=$(_jobs_req GET "/api/jobs?project=$project&limit=200" 2>/dev/null); then
  decline_all "ledger unreachable"
fi
printf '%s' "$JROWS" > "$TD/jobs.json"
if ! QROWS=$(queue_list "$project" 2>/dev/null); then
  decline_all "ledger unreachable"
fi
printf '%s\n' "$QROWS" > "$TD/queue.tsv"

# ---- 7. the open PRs --------------------------------------------------------
# GET /repos/<slug>/pulls?state=open, paged to 200 rows (REST caps per_page at
# 100 and the CLI's --limit was 200), then reshaped by jq into the SAME field
# names the classifier has always read — `head.ref` is `headRefName` and
# `draft` is `isDraft` — so only the transport moved.
RC=0
gh_rest_pr_list_all "$REPO" open 200 > "$TD/prs.raw.json" || RC=$?
[ "$RC" = 0 ] || decline_all "$(rest_reason 'pr list' "$RC")"
jq -c '[ .[] | {number, title, body, headRefName: (.head.ref // ""), isDraft: (.draft == true)} ]' \
  "$TD/prs.raw.json" > "$TD/prs.json" 2>/dev/null || : > "$TD/prs.json"
[ -s "$TD/prs.json" ] || decline_all "pr list unreadable"

# The ai-build state list answers "is blocker #M still open" and is bought at
# most ONCE per run, and only when some key's body actually carries a
# Blocked-by line. A list that fails leaves the file empty, which makes every
# blocker "missing" — and missing reads OPEN below, the fail-closed direction.
# `.pull_request` rows are dropped inside gh_rest_issue_list: GET /issues
# returns pull requests as issues and `gh issue list` did not, and a PR number
# colliding with a blocker number is the one shape that could say CLOSED here.
STATES="$TD/states.json"; STATES_DONE=0
fetch_states() {
  [ "$STATES_DONE" = 1 ] && return 0
  STATES_DONE=1
  local rc=0
  gh_rest_issue_list "$REPO" all ai-build 200 > "$STATES" || rc=$?
  if [ "$rc" != 0 ]; then
    : > "$STATES"
    rest_log_open "the ai-build state list" "$rc" "blockers read OPEN"
  fi
  [ -s "$STATES" ] || : > "$STATES"
}
: > "$STATES"

# ---- conditions 9-15, in one embedded python3 block -------------------------
# The bin/orphan-reconcile.sh shape. Written once into the run's own scratch dir
# and executed per key: same single block to read, one process per key instead
# of one heredoc re-expanded per key.
# It prints exactly one line — `OK` or `DECLINED <reason>` — and its exit code
# carries the two read failures bash has to name itself: 3 = the ledger files
# are unreadable, anything else non-zero = the issue answer is not usable.
cat > "$TD/fastpath.py" <<'PYEOF'
import json, os, re, subprocess, sys

def load(p, dflt):
    try:
        with open(p) as f:
            return json.load(f)
    except Exception:
        return dflt

issue = load(sys.argv[1], None)
prs   = load(sys.argv[2], [])
jobs  = load(sys.argv[3], None)
states = load(sys.argv[5], [])
if not isinstance(issue, dict) or "number" not in issue:
    sys.exit(1)                       # a malformed answer is not an empty issue
if not isinstance(jobs, dict):
    sys.exit(3)                       # the ledger, fail closed
try:
    with open(sys.argv[4]) as f:
        qlines = f.read().splitlines()
except Exception:
    sys.exit(3)
if not isinstance(prs, list):
    prs = []
if not isinstance(states, list):
    states = []

PFX       = os.environ["FP_PFX"]
N         = int(os.environ["FP_N"])
KEY       = os.environ["FP_KEY"]
HARNESS   = os.environ["FP_HARNESS"]
PROJECT   = os.environ["FP_PROJECT"]
BODY_FILE = os.environ["FP_BODY"]
FETCH_MAX = int(os.environ["FP_FETCH_MAX"])
# The blocker read is BASH's (BH-1163), because the REST contract, its rc
# 0/44/75 mapping and its ETag cache all live in bin/lib/gh-rest.sh and a
# python `subprocess.run(["gh", ...])` bypasses all three. But the blocker SET
# is only knowable here, after line_re/refs() have parsed the body — regexes
# that are pinned byte-identical to bin/orphan-reconcile.sh's and must not be
# respelled in bash. So this block runs twice for a key whose body carries a
# Blocked-by line: `needs` names the numbers and stops, bash reads them, and
# `decide` is the classifier exactly as it always was, reading those answers off
# disk. One process per key on the common path, which is every key with no
# Blocked-by line in it.
MODE      = os.environ.get("FP_MODE") or "decide"
EXTRA     = os.environ.get("FP_EXTRA") or ""

def decline(reason):
    print("DECLINED " + reason)
    raise SystemExit(0)

def answer(kind, n):
    """The REST answer bash pre-fetched for <kind>-<n>, or None when the read
    was declined, capped or never asked for. None is the fail-closed reading at
    the one call site below — an unreadable blocker is OPEN, never CLOSED."""
    if not EXTRA:
        return None
    try:
        with open(os.path.join(EXTRA, "%s-%d.json" % (kind, n))) as f:
            return json.load(f)
    except Exception:
        return None

# copied from bin/orphan-reconcile.sh — keep in step. The whole block is taken
# VERBATIM, `part_re` included (this script has no decompose-parent class), so
# that a diff of the two ranges is the drift check: the day these spellings
# disagree is the day one of the two launches a ticket the other holds.
# tests/launch-fastpath-test.sh T1.32 runs that diff, so the check is CI's and
# not a line in a doc nobody executes. The three HOLD regexes ride in on the
# environment from bin/lib/hold.sh (sourced above), which is why this block can
# be byte-identical to a reconciler that reads the same lib.
line_re   = re.compile(r"^[\s>*_\-#]*blocked[- ]by\b(.*)$", re.IGNORECASE | re.MULTILINE)
part_re   = re.compile(r"^[\s>*_\-#]*part of\b(.*)$", re.IGNORECASE | re.MULTILINE)
num_re    = re.compile(r"#(\d+)")
keynum_re = re.compile(r"(?<![A-Za-z0-9])" + re.escape(PFX) + r"-0*(\d+)(?![0-9])", re.IGNORECASE)
# The FULL key, dot suffix included. A decompose child's TITLE spells its child
# key (`TK-2416.0` in project-5 #2566) and its build's PR claims exactly that
# key, never `TK-2566` the issue number. keynum_re above truncates at the dot
# and would even read the child PR as a claim on the PARENT number; fullkey_re
# is the spelling that can see the child-keyed owner (the 2026-09-19 #2566/
# #2579 re-launch loop). Leading zeros on the number are stripped on BOTH sides
# of the comparison, mirroring keynum_re, so `ticket/TK-02416.0` and
# `TK-2416.0` meet; fullkey() is the one normalised spelling.
fullkey_re = re.compile(r"(?<![A-Za-z0-9])" + re.escape(PFX)
                        + r"-0*(\d+(?:\.\d+)*)(?![A-Za-z0-9])", re.IGNORECASE)
def fullkey(m):
    return (PFX + "-" + m.group(1)).upper()
# THE HOLD VOCABULARY, from bin/lib/hold.sh through the environment so this
# classifier and bin/blocked-resolver.sh's gate read one definition (BH-408).
# HOLD as a WORD and in capitals: `HOLD —`, `(HOLD)`, `HOLD:`. Never `hold` in
# prose ("until the operator lifts the hold" is a description of one, not a new one).
# The fallbacks are what this script did before the lib existed: the same word
# regex, and NO lift vocabulary — `(?!)` never matches — so an unsynced box
# behaves exactly as it did rather than guessing at a lift.
hold_re   = re.compile(os.environ.get("HOLD_WORD_RE")
                       or r"(?<![A-Za-z])HOLD(?![A-Za-z])")
# THE BODY TAKES A LINE, NOT A WORD (BH-1461). A ticket BODY is where this
# harness documents itself, so the capital word appears in it as a NOUN all the
# time — "a per-project HOLD row", "after the operator HOLD (...)" — and the
# word regex owned every such ticket for ever. `(?m)` is required by BOTH
# engines: Python `re` and jq's Perl-syntax Oniguruma both anchor `^` to the
# string without it (bin/lib/hold.sh carries the measurement).
body_re   = re.compile(os.environ.get("HOLD_BODY_RE")
                       or "(?m)^HOLD[ \t]*(?:[:—–-]|\r?$)")
# A TITLE HOLDS ONLY IN THE IDIOM — `(HOLD)`/`(ON HOLD)`/`[HOLD]`, or a leading
# `[KEY: ][ON ]HOLD` then `:` or a dash —
# never on the word in a title that names the feature (bin/lib/hold.sh,
# HOLD_TITLE_RE, 2026-09-28). The fallback is the same string.
title_re  = re.compile(os.environ.get("HOLD_TITLE_RE")
                       or r"\((?:ON[ \t]+)?HOLD\)|\[(?:ON[ \t]+)?HOLD\]|^[ \t]*(?:[A-Z]+-[0-9]+(?:\.[0-9]+)*[: \t]+)?(?:ON[ \t]+)?HOLD(?![A-Za-z_])[ \t]*[:—–-]")
lift_re   = re.compile(os.environ.get("HOLD_LIFT_RE") or r"(?!)")
liftneg_re = re.compile(os.environ.get("HOLD_NEG_RE") or r"(?!)")
close_re  = re.compile(r"\b(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)\s+#(\d+)", re.IGNORECASE)
# A LIFT WORD OPENING A COMMENT lifts whatever follows it (BH-3435, project-5
# #3354: "RELEASED … This supersedes the HOLD." read as a hold). Same fallback
# as the lift regex: an unsynced box lifts nothing new. Below close_re on
# purpose: the block above is bin/orphan-reconcile.sh's verbatim (T1.32).
lead_re   = re.compile(os.environ.get("HOLD_LIFT_LEAD_RE") or r"(?!)")
# A COMMENT OPENING WITH `HOLD:` or `HOLD —` holds whatever follows (BH-6091,
# #5962: "HOLD: the lead reversed the RESUME above" read as a lift). Asked after
# lead_re and before lift_re, the order bin/lib/hold.sh decides in. The same
# fallback: a box with an old hold.sh holds nothing new.
holdlead_re = re.compile(os.environ.get("HOLD_LEAD_RE") or r"(?!)")
# A COMMENT HOLDS ONLY WHEN ITS FIRST NON-BLANK LINE STARTS WITH HOLD (BH-6297,
# bin/lib/hold.sh HOLD_COMMENT_RE). Read only by the no-lib fallback walk in
# condition 12; the fallback is the same literal.
comment_re = re.compile(os.environ.get("HOLD_COMMENT_RE")
                        or r"\A[ \t\r\n]*HOLD(?![A-Za-z0-9_]|-[A-Za-z0-9])")

def refs(text):
    out = set()
    for m in num_re.finditer(text or ""):
        out.add(int(m.group(1)))
    for m in keynum_re.finditer(text or ""):
        out.add(int(m.group(1)))
    return out

title    = str(issue.get("title") or "")
body     = str(issue.get("body") or "")
labels   = issue.get("labels") or []
comments = issue.get("comments") or []

# ---- 9. the issue is open ---------------------------------------------------
if str(issue.get("state") or "").upper() != "OPEN":
    decline("issue not open")

# ---- 10. the label ----------------------------------------------------------
# An absent or malformed labels field is NOT an empty label set that passes: it
# is a label we could not read, and this is the direction that declines.
names = [str(l.get("name") or "") for l in labels if isinstance(l, dict)]
if "ai-build" not in names:
    decline("no ai-build label")

# ---- 11. the body is a spec, not a sentence ---------------------------------
# h2 or h3 HEADINGS, both of them, case-sensitive. "the Scope is broad" in prose
# is a description of a ticket, not a ticket.
# A hotfix is exempt (BH-7117): its body is an incident note (#7066), and a
# person put the label on. FP_HOTFIX is bash's hotfix_labels_json_has answer.
if os.environ.get("FP_HOTFIX") != "1" and not (
        re.search(r"^#{2,3}[ \t]*Scope\b", body, re.M)
        and re.search(r"^#{2,3}[ \t]*Acceptance tests\b", body, re.M)):
    decline("body lacks ## Scope / ## Acceptance tests")

# ---- 12. a human said not yet ----------------------------------------------
# ONE READING OF A HOLD (BH-6297). bin/lib/hold.sh's hold_classify decides it
# for triage, the conductor and the hold-push guard, and bash ran it on this
# issue and thread before this step: its verdict line arrives as FP_HOLD
# ("held|clear|unreadable<TAB><why>"). So the newest decisive PERSON comment
# wins here exactly as it does there: bots are skipped, NEEDS-HUMAN and
# human-fix markers park, the `hold` label holds, and a comment holds only when
# its first non-blank line starts with HOLD. Unreadable declines (fail closed).
FP_HOLD = os.environ.get("FP_HOLD") or ""
if FP_HOLD:
    verdict, _, why = FP_HOLD.partition("\t")
    tok = (why.split() or [""])[0]
    if verdict == "clear":
        pass
    elif verdict == "held":
        decline({"hold:comment": "HOLD in comment",
                 "hold:title": "HOLD in title",
                 "hold:body": "HOLD in body",
                 "hold:label": "HOLD label",
                 "hold:waiting-on-human": "waiting on a human",
                 "hold:human-fix": "human fix in progress",
                 "abandon:comment": "ABANDON in comment"}.get(tok, "held (%s)" % tok))
    else:
        decline("hold unreadable")
else:
    # THE NO-LIB FALLBACK: a box mid-sync without bin/lib/hold.sh. The thread
    # is walked newest-first (the payload is oldest-first), the first DECISIVE
    # comment decides, and neutral comments are skipped. A comment that opens
    # with `HOLD:` or `HOLD —` holds before the lift vocabulary is asked
    # (HOLD_LEAD_RE, BH-6091), the order bin/lib/hold.sh decides in. No bot
    # filter and no lift vocabulary (the fallbacks above never match), so an unsynced box
    # holds at least as much as the lib would. Our own ambiguity note
    # (hold_ambiguous_note) names the lift words, so it is never read.
    thread = [str(c.get("body") or "") for c in comments if isinstance(c, dict)]
    thread = [c for c in thread if "<!-- harness:hold-ambiguous" not in c]
    held = None
    for c in reversed(thread):
        if lead_re.search(c):
            if liftneg_re.search(c):
                continue
            held = False
            break
        if holdlead_re.search(c):
            held = True
            break
        if lift_re.search(c) and not liftneg_re.search(c):
            held = False
            break
        if comment_re.search(c):
            held = True
            break
    if held is True:
        decline("HOLD in comment")
    if held is None:
        if title_re.search(title):
            decline("HOLD in title")
        # The BODY arm is the line regex, not the word one (BH-1461): a ticket
        # that merely DESCRIBES the hold mechanism ("a per-project HOLD row")
        # must build.
        if body_re.search(body):
            decline("HOLD in body")

# ---- 13. the blockers -------------------------------------------------------
# A Blocked-by line naming the issue itself is not a blocker (a ticket cannot
# wait for itself, and declining it would be a dead end).
blockers = set()
for m in line_re.finditer(body):
    blockers |= refs(m.group(1))
blockers.discard(N)
# STACK MODE (BH-3684): the caller names the one open blocker it is stacking on.
SP = int(os.environ.get("FP_STACK_PARENT") or 0)
st = {}
missing = []
if blockers:
    for i in states:
        if isinstance(i, dict) and "number" in i:
            st[int(i["number"])] = str(i.get("state") or "").upper()
    # The de-labelled decompose parent the ai-build list cannot carry. Capped,
    # and an unreadable one — or one past the cap — reads OPEN, so dep-verify
    # gets the call rather than this script guessing CLOSED.
    missing = sorted(b for b in blockers if b not in st)
# `needs` STOPS HERE. Conditions 9-12 have already run (a decline there is final
# and bash never asks for a second pass), and the numbers named below are the
# only thing this pass exists to produce.
if MODE == "needs":
    print("NEEDS " + " ".join(str(b) for b in missing[:FETCH_MAX]))
    raise SystemExit(0)
for b in missing[:FETCH_MAX]:
    d = answer("blocker", b)
    st[b] = str(d.get("state") or "").upper() if isinstance(d, dict) and d.get("state") else "OPEN"
for b in missing[FETCH_MAX:]:
    st[b] = "OPEN"
# The open parent is what makes a stack launchable, so it is not asked of
# dep-verify.sh; every OTHER open blocker still is (single-parent rule).
if SP and (SP not in blockers or st.get(SP, "OPEN") != "OPEN"):
    decline("stack parent #%d is not an open blocker" % SP)
for b in sorted(blockers):
    if st.get(b, "OPEN") != "OPEN":
        continue
    if SP and b == SP:
        continue
    # `Blocked-by:` is a claim somebody typed once; bin/dep-verify.sh is the
    # harness checking it. SOFT (ordering preference only) is the ONLY
    # verdict that lets a child through here — UNKNOWN included, because the
    # fast path is the cheap lane and an unverified chain belongs to triage.
    env = dict(os.environ)
    env["DEP_CHILD_BODY_FILE"] = BODY_FILE
    verdict, why = "UNKNOWN", "dep-verify.sh gave no usable answer"
    try:
        out = subprocess.run([os.path.join(HARNESS, "bin", "dep-verify.sh"),
                              PROJECT, str(N), str(b)],
                             capture_output=True, text=True, timeout=90, env=env)
        first = (out.stdout or "").strip().splitlines()
        toks = first[0].split(None, 1) if first else []
        if toks and toks[0] in ("HARD", "SOFT", "UNKNOWN"):
            verdict = toks[0]
            why = toks[1].strip() if len(toks) > 1 else ""
    except Exception:
        pass
    if verdict != "SOFT":
        decline("blocker #%d open (%s %s)" % (b, verdict, why[:120]))

# ---- 14. an open PR already carries this key --------------------------------
# copied from bin/orphan-reconcile.sh's owner class (b), with drafts skipped: a
# draft PR is somebody's work in progress, not the merge conductor's.
pr_owns = {}
for p in prs:
    if not isinstance(p, dict):
        continue
    if p.get("isDraft") is True:
        continue
    num = p.get("number")
    hay = " ".join(str(p.get(k) or "") for k in ("title", "headRefName"))
    claims = {int(m.group(1)) for m in keynum_re.finditer(hay)}
    claims |= {int(m.group(1)) for m in num_re.finditer(str(p.get("title") or ""))}
    # The BODY counts only through a closing keyword. A plan body that merely
    # lists `#672, #673` is a reading list, not a claim of ownership.
    claims |= {int(m.group(1)) for m in close_re.finditer(str(p.get("body") or ""))}
    for x in claims:
        pr_owns.setdefault(x, num)
if N in pr_owns:
    decline("open PR #%s" % pr_owns[N])

# ---- 14b. an open PR that claims the FULL key this issue's title LEADS with --
# copied from bin/orphan-reconcile.sh's owner class (b2), drafts skipped for the
# same reason as (b) above. A decompose child's PR carries the child key
# (`TK-2416.0`) and never the issue NUMBER, so the number map above cannot see
# it and `keynum_re` even reads that PR as a claim on the PARENT — the
# 2026-09-19 #2566/#2579 re-launch loop. Only the LEADING key is the issue's own
# name (the decompose-child convention this rests on); a key named later in the
# title (`TK-910: follow-up to TK-902.0`) is somebody else's and must not park
# this ticket.
pr_keys = {}
for p in prs:
    if not isinstance(p, dict):
        continue
    if p.get("isDraft") is True:
        continue
    num = p.get("number")
    hay = " ".join(str(p.get(k) or "") for k in ("title", "headRefName"))
    for m in fullkey_re.finditer(hay):
        pr_keys.setdefault(fullkey(m), num)
m = fullkey_re.match(title.lstrip())
if m and fullkey(m) in pr_keys:
    tk = fullkey(m)
    decline("open PR #%s (title key %s)" % (pr_keys[tk], tk))

# ---- 15. a live ledger row --------------------------------------------------
LIVE = ("queued", "claimed", "running")
live_keys = {}

def note(tokens, status, label):
    for k in {t for t in tokens if t}:
        if status in LIVE:
            live_keys.setdefault(k, label)

for j in (jobs.get("jobs") or []):
    if not isinstance(j, dict):
        continue
    meta = j.get("meta")
    if isinstance(meta, str):
        try:
            meta = json.loads(meta)
        except Exception:
            meta = {}
    if not isinstance(meta, dict):
        meta = {}
    # A build row spells the ticket `TK-721` and a triage shard spells it `1149`,
    # and the meta carries the other half.
    toks = {str(j.get("ticket_id") or ""), str(meta.get("key") or ""),
            str(meta.get("ticket_id") or "")}
    note(toks, str(j.get("status") or "").lower(), "ledger job %s" % (j.get("id") or "?"))

for ln in qlines:
    c = ln.split("\t")
    if len(c) < 8:
        continue
    note({c[1], c[2]}, c[3].lower(), "queue row %s" % c[3])

for tok in (KEY, str(N)):
    if tok in live_keys:
        decline("ledger: %s" % live_keys[tok])

print("OK")
PYEOF

# One invocation, two modes (BH-1163). `needs` names the blocker numbers bash
# has to read and stops; `decide` is the whole classifier. The environment is
# identical in both, so the conditions are evaluated in the same order against
# the same inputs and "first failure wins" (D13) is unchanged.
classify() { # classify <needs|decide>   — reads the loop's $n/$KEY/$IJ/$BODYF
  FP_PFX="$PFX" FP_N="$n" FP_KEY="$KEY" FP_HARNESS="$HARNESS" \
  FP_PROJECT="$project" FP_BODY="$BODYF" FP_FETCH_MAX="$BLOCKER_FETCH_MAX" \
  FP_MODE="$1" FP_EXTRA="$TD/extra" FP_STACK_PARENT="$FP_SP" FP_HOLD="$FP_HOLD" \
  FP_HOTFIX="$FP_HOTFIX" python3 "$TD/fastpath.py" "$IJ" "$TD/prs.json" "$TD/jobs.json" \
          "$TD/queue.tsv" "$STATES" 2>/dev/null
}

MARKDIR="$HARNESS/state/orphan-reconcile/$project"

# THE HOTFIX HOLD ALERT (BH-6297). #5239, a launch blocker with the hotfix
# label, waited 4 h 27 min on a HOLD nobody had placed, and only this log said
# so. A hotfix declined for a HOLD now writes ONE ALERTS line that quotes the
# line hold_classify decided on, so a false HOLD is seen in minutes.
#   fp_hold_decline <key-as-given> <reason> — decline, then alert when all of:
#   FP_HOLD is a `held` verdict, the reason is condition 12's, and the issue
#   carries the hotfix label (hotfix_labels_json_has; lane off = no label).
#   Once per (KEY, verdict tail): a marker under state/fastpath-hold-alert/.
#   The akey is alert:fastpath-hold-<project>-<KEY>, one console row per KEY.
#   bin/alert-line.sh is the only writer; a box without it writes nothing.
#   The decline is logged first, so it never depends on the alert.
fp_hold_decline() {
  local k="$1" r="$2" tail m
  decline "$k" "$r"
  case "$FP_HOLD" in "held	"*) ;; *) return 0 ;; esac
  case "$r" in
    "HOLD in comment"|"HOLD in title"|"HOLD in body"|"HOLD label"|"waiting on a human"\
    |"human fix in progress"|"ABANDON in comment"|"held ("*) ;;
    *) return 0 ;;
  esac
  command -v hotfix_labels_json_has >/dev/null 2>&1 || return 0
  hotfix_labels_json_has "$(cat "$TD/issue-$n.raw.json" 2>/dev/null)" "$HARNESS" || return 0
  tail="${FP_HOLD#*	}"
  m="$HARNESS/state/fastpath-hold-alert/$project/$KEY.$(printf '%s' "$tail" | sha1sum | cut -c1-12)"
  [ -e "$m" ] && return 0
  mkdir -p "${m%/*}" 2>/dev/null || return 0
  [ -x "$HARNESS/bin/alert-line.sh" ] || return 0
  "$HARNESS/bin/alert-line.sh" --id "fastpath-hold-$project-$KEY" --project "$project" \
    "fastpath: hotfix $KEY (#$n) declined: $r. Line: $tail. If this is not a HOLD on this ticket, post a comment that starts with RESUME on #$n." \
    >/dev/null 2>&1 </dev/null || true
  : > "$m" 2>/dev/null || true
  return 0
}

# ---- conditions 16-18: the three LOCAL reads --------------------------------
# These three are the only conditions a CONCURRENT run of this script can change
# under us: the build-key lock, the build record a spawn creates, and the marker
# a spawn writes. So they are evaluated TWICE — once per key in condition order
# (the reason named stays the FIRST thing that was wrong, D13), and again INSIDE
# the launch lock. That second read is what makes the lock the one the ticket
# asks for, "around eligibility+launch": the marker is read and written in the
# same critical section, so two runs that both got past the pre-check cannot both
# spawn. Without it the first run writes the marker and releases the lock in a
# few ms and the second takes the free lock and spawns the same build again.
# Conditions 9-15 stay OUTSIDE the lock: they are GitHub and ledger state no peer
# run mutates, and buying those reads under a lock would make it a queue (D33).
# It is condition 18 that does the deduping, so the IN-LOCK read of it is floored
# at 60 seconds: a box that sets ORPHAN_GRACE_MIN=0 still gets one launch per key
# rather than a lock that only serialises two identical builds.
#
# rc 0 = launch. rc 1 = LOCAL_WHY is the reason.
#
# The second argument is `floor`, and only the IN-LOCK call passes it: it puts a
# 60-second floor under condition 18's window so that ORPHAN_GRACE_MIN=0 cannot
# switch the dedupe off. The knob is the reconciler's grace window, shared on
# purpose; tuned eager there it used to leave this lock serialising two
# identical builds instead of stopping the second one. The PRE-check keeps the
# raw window, so the reason a key is declined outside the lock is still the
# operator's own setting.
LOCAL_WHY=""
local_eligible() {            # local_eligible <KEY> [floor]
  local K="$1" mark mt age d W
  LOCAL_WHY=""

  # ---- 16. something on this box is already building it --------------------
  # The lock is TESTED, never taken: bin/run-build.sh is the one process that
  # holds a build-key lock (CLAUDE.md: locks are DEDUPE).
  if command -v preplan_held >/dev/null 2>&1 \
     && preplan_held "$HARNESS/locks/build-key-$project-$K.lock"; then
    LOCAL_WHY="already building (build-key lock held)"; return 1
  fi

  # ---- 17. it has been built before ----------------------------------------
  # ANY build record, swept or not: a second run of a ticket that already has
  # one is a decision about the FIRST run's result, and that decision belongs to
  # triage, which can read the thread.
  for d in "$HARNESS/builds/$project-$K-"*/ "$HARNESS/builds/pool-$project-$K-"*/; do
    [ -d "$d" ] || continue
    LOCAL_WHY="prior build record exists — relaunches are triage's call"; return 1
  done
  # A record bin/builds-retention.sh moved to builds-archive/ is still one.
  if command -v ba_has_key >/dev/null 2>&1 && ba_has_key "$HARNESS" "$project" "$K"; then
    LOCAL_WHY="prior build record exists (archived) — relaunches are triage's call"; return 1
  fi

  # ---- 18. the reconciler got there first ----------------------------------
  # Or, under the lock, a peer run of this script did: it writes this same
  # marker, so it gets this same answer.
  mark="$MARKDIR/$K.enqueued"
  [ -f "$mark" ] || return 0
  mt=$(stat -c %Y "$mark" 2>/dev/null || stat -f %m "$mark" 2>/dev/null || echo 0)
  case "$mt" in ''|*[!0-9]*) mt=0 ;; esac
  # A marker we cannot age is a marker, and fail closed means the reconciler
  # keeps it — never "old enough" by default (D11).
  if [ "$mt" = 0 ]; then
    LOCAL_WHY="reconciler enqueued it (marker mtime unreadable)"; return 1
  fi
  age=$(( $(date -u +%s) - mt ))
  W=$((GRACE_MIN * 60))
  [ "${2:-}" = floor ] && [ "$W" -lt 60 ] && W=60
  if [ "$age" -lt "$W" ]; then
    LOCAL_WHY="reconciler enqueued it $((age / 60))m ago"; return 1
  fi
  return 0
}

idx=0
for key in "${KEYS[@]}"; do
  idx=$((idx+1))
  KSTART=$(date +%s)
  if [ "$idx" -gt "$MAX_KEYS" ]; then
    decline "$key" "over the $MAX_KEYS-key run cap"; continue
  fi

  # ---- 8. the key, then the issue ------------------------------------------
  lk=$(printf '%s' "$key" | tr '[:upper:]' '[:lower:]')
  lp=$(printf '%s' "$PFX" | tr '[:upper:]' '[:lower:]')
  num="$lk"
  case "$lk" in "$lp"-*) num="${lk#"$lp"-}" ;; esac
  case "$num" in ''|*[!0-9]*) decline "$key" "unparseable key"; continue ;; esac
  n=$(printf '%s' "$num" | sed 's/^0*//')
  [ -n "$n" ] || { decline "$key" "unparseable key"; continue; }
  KEY="$PFX-$n"
  lc=$(printf '%s' "$KEY" | tr '[:upper:]' '[:lower:]')

  # THE ISSUE AND ITS THREAD, over REST (BH-1163). Two reads, not one: the issue
  # payload carries `comments` as an integer COUNT, and the classifier walks
  # comment BODIES. Left as the count it would raise on the first iteration and
  # every key would decline "issue unreadable", so the merge below is not
  # optional — and the thread is bought only when the count says there is one.
  IJ="$TD/issue-$n.json"
  RC=0
  gh_rest GET "repos/$REPO/issues/$n" > "$TD/issue-$n.raw.json" || RC=$?
  if [ "$RC" != 0 ]; then decline "$key" "$(rest_reason "issue #$n" "$RC")"; continue; fi
  if ! jq -e 'type == "object" and has("number")' "$TD/issue-$n.raw.json" >/dev/null 2>&1; then
    decline "$key" "issue unreadable"; continue
  fi
  CNT=$(jq -r '.comments // 0' "$TD/issue-$n.raw.json" 2>/dev/null)
  case "$CNT" in ''|*[!0-9]*) CNT=0 ;; esac
  CJ="$TD/comments-$n.json"
  if [ "$CNT" -gt 0 ]; then
    RC=0
    gh_rest_issue_comments "$REPO" "$n" 200 > "$CJ" || RC=$?
    if [ "$RC" != 0 ]; then decline "$key" "$(rest_reason "thread #$n" "$RC")"; continue; fi
    GOT=$(jq 'if type == "array" then length else -1 end' "$CJ" 2>/dev/null)
    case "$GOT" in ''|*[!0-9]*) GOT=-1 ;; esac
    if [ "$GOT" -lt 0 ]; then decline "$key" "thread unreadable"; continue; fi
    # A READ THAT STOPPED SHORT IS NOT THE THREAD. The row cap in
    # gh_rest_issue_comments trims OLDEST-first, so the bodies a truncated read
    # is missing are the NEWEST — which is where the newest-human-comment-wins
    # walk below starts, and where a HOLD written today lives (BH-408). "Nobody
    # could see the thread" and "nobody held it" are different sentences.
    if [ "$GOT" -lt "$CNT" ]; then decline "$key" "thread truncated ($GOT of $CNT)"; continue; fi
  else
    printf '[]' > "$CJ"
  fi
  if ! jq -c --slurpfile c "$CJ" '.comments = $c[0]' "$TD/issue-$n.raw.json" > "$IJ" 2>/dev/null; then
    decline "$key" "issue unreadable"; continue
  fi
  BODYF="$TD/body-$n.txt"
  jq -r '.body // ""' "$IJ" > "$BODYF" 2>/dev/null || : > "$BODYF"
  # Condition 12's verdict, from the shared reader (BH-6297). Empty only on a
  # box without bin/lib/hold.sh, where the classifier walks the thread itself.
  FP_HOLD=""
  if command -v hold_classify >/dev/null 2>&1; then
    FP_HOLD=$(hold_classify "$TD/issue-$n.raw.json" "$CJ" 2>/dev/null)
    [ -n "$FP_HOLD" ] || FP_HOLD="unreadable	hold_classify printed nothing"
  fi
  # Condition 11's hotfix exemption (BH-7117). The lane off or no lib: 0.
  FP_HOTFIX=0
  command -v hotfix_labels_json_has >/dev/null 2>&1 \
    && hotfix_labels_json_has "$(cat "$TD/issue-$n.raw.json" 2>/dev/null)" "$HARNESS" && FP_HOTFIX=1

  # ---- 13's reads: the blockers, named by the classifier and read by bash ---
  # Only for a body that actually carries a Blocked-by line — the same grep that
  # has always gated the state list. Every other key runs the classifier once,
  # exactly as before. A blocker two keys share is read once per run: the answer
  # is keyed by NUMBER in the run's scratch and reused.
  if grep -qiE '^[[:space:]>*_#-]*blocked[- ]by' "$BODYF"; then
    fetch_states
    mkdir -p "$TD/extra" 2>/dev/null
    NEEDS=$(classify needs)
    PY_RC=$?
    if [ "$PY_RC" = 3 ]; then decline "$key" "ledger unreachable"; continue; fi
    if [ "$PY_RC" != 0 ]; then decline "$key" "issue unreadable"; continue; fi
    case "$NEEDS" in
      "DECLINED "*) fp_hold_decline "$key" "${NEEDS#DECLINED }"; continue ;;
      NEEDS|"NEEDS "*)
        # shellcheck disable=SC2086  # the numbers are the classifier's own, one per word
        for b in ${NEEDS#NEEDS}; do
          [ -f "$TD/extra/blocker-$b.json" ] && continue
          RC=0
          gh_rest GET "repos/$REPO/issues/$b" > "$TD/extra/blocker-$b.json" || RC=$?
          [ "$RC" = 0 ] && continue
          rm -f "$TD/extra/blocker-$b.json"
          rest_log_open "the blocker read for #$b" "$RC" "read OPEN"
        done ;;
      *) decline "$key" "issue unreadable"; continue ;;
    esac
  fi

  # ---- 9-15 ----------------------------------------------------------------
  VERDICT=$(classify decide)
  PY_RC=$?
  if [ "$PY_RC" = 3 ]; then decline "$key" "ledger unreachable"; continue; fi
  if [ "$PY_RC" != 0 ]; then decline "$key" "issue unreadable"; continue; fi
  case "$VERDICT" in
    OK) ;;
    "DECLINED "*) fp_hold_decline "$key" "${VERDICT#DECLINED }"; continue ;;
    *) decline "$key" "issue unreadable"; continue ;;
  esac

  # ---- 15c. the dispatch mode (BH-6350) -------------------------------------
  # hotfix-only holds a key with no hotfix label that is not on the allow-list.
  # The key is still printed as declined, so the caller contract holds, but the
  # per-key log line is replaced by ONE line per run after the loop. Nothing is
  # written to the ticket: it keeps ai-build and waits for the next run.
  if [ "$DM_MODE" = hotfix-only ]; then
    dm_hf=0
    command -v hotfix_labels_json_has >/dev/null 2>&1 \
      && hotfix_labels_json_has "$(cat "$TD/issue-$n.raw.json" 2>/dev/null)" "$HARNESS" && dm_hf=1
    if ! dm_admit_ticket "$n" "$dm_hf"; then
      printf '%s\n' "$key"; declined=$((declined+1)); DM_WAIT="${DM_WAIT:+$DM_WAIT }$KEY"
      continue
    fi
  fi

  # ---- 16-18, the pre-check ------------------------------------------------
  # Cheap, in condition order, and read again under the launch lock below.
  if ! local_eligible "$KEY"; then
    decline "$key" "$LOCAL_WHY"; continue
  fi

  # ---- the launch ----------------------------------------------------------
  # The lock is DEDUPE and it is SECONDS long: it covers the last three
  # conditions, the marker and the spawn, and the lane's lock fds are closed in
  # the child by bin/lib/lock-hygiene.sh's lock_spawn_unheld — the one place
  # that knows which fds a lane holds — so bin/run-build.sh never inherits this
  # lock or the caller's tick lock. A lock held for the length of a build is a
  # queue, and a queue is how a wave of tickets turns into an afternoon (the operator,
  # 2026-09-13).
  # A redirection leaves the argv identical to the SOP line.
  MARK="$MARKDIR/$KEY.enqueued"
  OUTCOME=$(
    exec 9>"$HARNESS/locks/launch-fastpath-$project-$KEY.lock" 2>/dev/null || { echo HELD; exit 0; }
    flock -n 9 || { echo HELD; exit 0; }
    # Conditions 16-18 AGAIN, now that nothing else can be between its own
    # marker read and its own spawn — whoever holds this lock is the only
    # process that can write this key's marker. Prints nothing itself, so the
    # only thing on this subshell's stdout is the outcome word.
    local_eligible "$KEY" floor || { printf 'DECLINED %s\n' "$LOCAL_WHY"; exit 0; }
    # `setsid … &` puts the exec failure in a child this shell can never see, so
    # the one repeatable configuration failure — run-build.sh not executable — is
    # checked HERE, before the marker is written. D9: a failed spawn is never a
    # launch.
    [ -x "$HARNESS/bin/run-build.sh" ] || { echo "FAILED 126"; exit 0; }
    mkdir -p "$MARKDIR" 2>/dev/null
    # The marker BEFORE the spawn: it is bin/orphan-reconcile.sh's own grace
    # input, so a run killed between the two still leaves the reconciler standing
    # down instead of launching a second copy.
    : > "$MARK" 2>/dev/null
    # Stack mode hands the base to bin/run-build.sh by environment, the way
    # bin/lib/rb/gates.sh reads it; the argv stays the SOP line.
    if [ -n "$FP_SB" ]; then
      export STACK_BASE="$FP_SB"
      [ -z "$FP_SPR" ] || export STACK_PARENT_PR="$FP_SPR"
    fi
    lock_spawn_unheld setsid "$HARNESS/bin/run-build.sh" "$project" "$n" "$KEY" \
      > "$HARNESS/logs/$project.$lc-build.out" 2>&1
    rc=$?
    [ "$rc" -eq 0 ] || { rm -f "$MARK" 2>/dev/null; echo "FAILED $rc"; exit 0; }
    echo LAUNCHED
  )
  case "$OUTCOME" in
    LAUNCHED) ;;
    HELD)         decline "$key" "racing launch, declined"; continue ;;
    "DECLINED "*) decline "$key" "${OUTCOME#DECLINED }"; continue ;;
    "FAILED "*)   decline "$key" "launch failed (${OUTCOME#FAILED })"; continue ;;
    *)            decline "$key" "launch failed (no answer from the launch lock)"; continue ;;
  esac
  log "FASTPATH $KEY (issue #$n) — launched${FP_SB:+ stacked on $FP_SB (parent #$FP_SP)}"
  # Only a key that LAUNCHED reaches here, and only after the spawn (D9).
  run_beat "$(jq -nc --arg rkey "run:$project:$KEY:fastpath:$(date +%s)" --arg p "$project" \
    --arg s "fastpath $KEY: launched build" --arg st "$(date -u -d "@$KSTART" '+%Y-%m-%dT%H:%M:%SZ')" \
    --arg fin "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    '{kind:"run",rkey:$rkey,project:$p,run_kind:"triage",rc:0,summary:$s,started_at:$st,finished_at:$fin}')"

  # ---- the wake key this launch consumed -----------------------------------
  # bin/run-triage.sh reads state/wake-keys-<project> one-shot, so a key that is
  # now building must not also buy a triage session. Rewritten in place under a
  # short flock (the inode the lock is on stays the same), and only ever
  # shrinking: a concurrent reader sees the full file or the shrunk one, never a
  # torn write.
  #
  # The CONSUMER takes no lock: bin/lib/rt/scope.sh reads the file and `rm -f`s
  # it, so this flock only excludes other copies of this script. That one-shot
  # consume can land between the read below and the rewrite, and a rewrite that
  # did not look would recreate a file scope.sh had already handed to a tick —
  # "a key that outlived its wake would scope some later tick to a ticket nobody
  # rang about" (scope.sh). So the path is re-tested immediately before the
  # write, and a file that is gone stays gone.
  KF="$HARNESS/state/wake-keys-$project"
  if [ -f "$KF" ]; then
    (
      exec 8>>"$KF" 2>/dev/null || exit 0
      flock -w 5 8 2>/dev/null || exit 0
      keep=$(grep -vixE "$n|$KEY" "$KF" 2>/dev/null | grep -v '^[[:space:]]*$')
      [ -f "$KF" ] || exit 0
      if [ -z "$keep" ]; then rm -f "$KF"; else printf '%s\n' "$keep" > "$KF"; fi
    )
  fi
done

if [ -n "$DM_WAIT" ]; then
  DM_N=$(printf '%s' "$DM_WAIT" | wc -w | tr -d ' ')
  log "DISPATCH-MODE hotfix-only: $DM_N key(s) wait ($DM_WAIT); allow-list: $(dm_allow_text)$([ "${DM_BAD:-0}" = 1 ] && printf " (row value unparseable: '%s')" "$DM_VALUE")$( command -v hotfix_lane_on >/dev/null 2>&1 && [ "$(hotfix_lane_on "$HARNESS")" = 0 ] && printf ' (hotfix lane is off; only the allow-list builds)')"
fi
[ "$declined" -eq 0 ] && exit 0
exit 1
