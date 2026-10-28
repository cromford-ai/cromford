#!/bin/bash
# load-project.sh — onboard a repo into the harness fleet in one command.
#
#   load-project.sh <owner/repo> [--project <name>] [--prod <url>] [--box <host>]
#                   [--prefix <KEY>] [--base <branch>] [--context <file>]
#                   [--no-bootstrap] [--vmap-ticket] [--arch-ticket] [--fly]
#                   [--require-readiness <n>] [--repo-dir <checkout>]
#                   [--tracker linear|jira --prefix <KEY>]
#
# What it does (idempotent — re-running skips what exists). Steps 1-5 live in
# bin/lib/onboard-stations.sh (obs_register, obs_prompt, obs_label, obs_box),
# shared with the onboarding runner; 4b-4d stay in this file:
#   1. registry: appends a fleet.conf row (GitHub-Issues board: prefix "-",
#      free cron offset among the target box's projects, box column set).
#      REGISTRY_SOURCE=db (BH-5650): writes the same row through
#      bin/registry.sh add-project instead (needs REGISTRY_ADMIN_TOKEN, FATAL
#      without it — never a fleet.conf append), reads it back from the
#      registry, and fleet.conf is neither changed nor committed
#   2. prompt: renders prompts/<project>.md from prompts/TEMPLATE-GH.md
#   3. commits + pushes cromford (pull --rebase first — the hub pushes too)
#   4. ensures the `ai-build` label exists on the repo
#   4b. (--vmap-ticket) files the verification-map backfill ticket from
#      docs/VMAP-BACKFILL-TICKET.md — opt-in, because filing work on someone's
#      board is not something an onboarding command should do by surprise
#   4c. (--arch-ticket) files the agent-architecture audit ticket from
#      docs/ARCH-AUDIT-TICKET.md — opt-in for the same reason
#   4d. (--fly) appends the project to fly/onboard-queue.conf IN THE SAME COMMIT,
#      so the hub picks the onboarding up on its next fleet-propagate tick and
#      runs bin/fly-onboard.sh there. Opt-in, and it queues rather than doing it
#      inline: onboarding needs the hub's flyctl session, which this command has
#      no way to reach from a Mac (BH-662)
#   5. over ssh to the box: pulls /root/harness-checkout, syncs runtime, writes
#      an env stub, runs bootstrap-machine.sh <project> (crons, clone, smoke)
#
# --tracker linear|jira (BH-7924) makes the project a Linear or Jira project.
# It needs --prefix <KEY>: the Linear team key or the Jira project key, checked
# with the adapter's own pattern; anything else is rc 2 and nothing is written.
# Before step 1 it writes the settings rows through bin/jobs-client.sh
# setting-set: linear tracker_linear.<p>.team=<KEY>; jira
# tracker_jira.<p>.write_projects, read_projects and comment_projects=<KEY>;
# then tracker_adapter.<p>=<adapter> (last, so a failed write never routes the
# project to an adapter without its key). A failed write is FATAL before any
# registry write. fleet.conf column 4 stays `-`. Settings are D1 in file and
# db mode alike. The credentials stay in env/<project>.env on the box (see
# docs/connecting-a-board.md); bin/connection-probe.sh <project> checks them.
#
# --require-readiness <n> grades a LOCAL checkout of the repo (--repo-dir) with
# bin/readiness-report.sh and refuses to enrol it below level n, before step 1.
# Default 0: the gate is skipped entirely and nothing changes for any project
# that was loaded without it. See docs/READINESS.md.
#
# Run from ANY cromford checkout (Mac or hub) with: git push access, an
# authed `gh`, and ssh to the target box. Default box: box-small
# (the shared small-projects box). The box's gh PAT must cover the repo —
# box-small carries the operator's global PAT, so any operator/example-org repo
# works with zero PAT ceremony.
#
# The watcher is label-gated: loading a project builds NOTHING until an issue
# is labeled `ai-build` (see prompts/TEMPLATE-GH.md THE PRIME RULE). Handoff
# from local planning: the /harness skill (skills/harness/SKILL.md).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
# The App-token helper. `|| true` everywhere: this script is set -e.
# shellcheck source=bin/lib/gh-app-auth.sh
[ -r "$ROOT/bin/lib/gh-app-auth.sh" ] && . "$ROOT/bin/lib/gh-app-auth.sh" || true
# BH-1651: the dedupe title lists are REST. gh-rest-list.sh sources gh-rest.sh.
# shellcheck source=bin/lib/gh-rest-list.sh
[ -r "$ROOT/bin/lib/gh-rest-list.sh" ] && . "$ROOT/bin/lib/gh-rest-list.sh" || true

SLUG="${1:?usage: load-project.sh <owner/repo> [--project name] [--prod url] [--box host] [--prefix KEY] [--base branch] [--context file] [--no-bootstrap] [--require-readiness <n> --repo-dir <checkout>] [--tracker linear|jira --prefix KEY]}"
shift
# BH-4080: the default box name and the harness repo the box clones live in
# the deployment defaults home.
# shellcheck source=bin/lib/deployment.sh
. "${HARNESS_DEPLOYMENT_FILE-$ROOT/bin/lib/deployment.sh}"
# Steps 1-5 are the onboarding stations (BH-7934.1), shared with the onboarding
# runner. A scratch tree that copied this script without its lib has none beside
# it, so the lib is then taken from beside the deployment file (BH-4080).
OBS_LIB="$(dirname "$0")/lib/onboard-stations.sh"
[ -r "$OBS_LIB" ] || OBS_LIB="$(dirname "${HARNESS_DEPLOYMENT_FILE:-$OBS_LIB}")/onboard-stations.sh"
# shellcheck source=bin/lib/onboard-stations.sh
. "$OBS_LIB" || exit 1
PROJECT="" PROD="-" BOX="${HARNESS_BOX_PREFIX}small" PREFIX="" BASE="" CONTEXT_FILE="" BOOTSTRAP=1 VMAP_TICKET=0 ARCH_TICKET=0 FLY=0
QUEUE="fly/onboard-queue.conf"
REQUIRE_READINESS=0 REPO_DIR="" TRACKER=""
while [ $# -gt 0 ]; do
  case "$1" in
    --require-readiness) REQUIRE_READINESS="$2"; shift 2 ;;
    --repo-dir)          REPO_DIR="$2"; shift 2 ;;
    --project) PROJECT="$2"; shift 2 ;;
    --prod)    PROD="$2"; shift 2 ;;
    --box)     BOX="$2"; shift 2 ;;
    --prefix)  PREFIX="$2"; shift 2 ;;
    --base)    BASE="$2"; shift 2 ;;
    --context) CONTEXT_FILE="$2"; shift 2 ;;
    --no-bootstrap) BOOTSTRAP=0; shift ;;
    --vmap-ticket)  VMAP_TICKET=1; shift ;;
    --arch-ticket)  ARCH_TICKET=1; shift ;;
    --fly)          FLY=1; shift ;;
    --tracker)      [ $# -ge 2 ] || { echo "load-project: --tracker takes linear or jira"; exit 2; }
                    TRACKER="$2"; shift 2 ;;
    *) echo "unknown flag $1"; exit 2 ;;
  esac
done

# >>> tracker flag (BH-7924) -- checked before any write, as the gates below
if [ -n "$TRACKER" ]; then
  case "$TRACKER" in
    linear) TRK_KEY_RE='^[A-Z][A-Z0-9_]{0,9}$' ;;   # trk_linear_context's team key
    jira)   TRK_KEY_RE='^[A-Z][A-Z0-9_]{1,9}$' ;;   # trk_jira_context's project key
    *) echo "load-project: --tracker takes linear or jira (got '$TRACKER'); nothing was written"; exit 2 ;;
  esac
  [ -n "$PREFIX" ] || { echo "load-project: --tracker $TRACKER needs --prefix <KEY> (the $TRACKER key); nothing was written"; exit 2; }
  [[ "$PREFIX" =~ $TRK_KEY_RE ]] \
    || { echo "load-project: --prefix '$PREFIX' is not a $TRACKER key ($TRK_KEY_RE); nothing was written"; exit 2; }
fi
# <<< tracker flag

# >>> project name length
# The worker refuses a settings key over 64 chars (SETTING_KEY_RE,
# worker/jobs/src/lib/core.js). A project-scoped key is lane.<lane>.<project>.<knob>,
# and the longest lane+knob part is 45 chars, so a project name may have 19.
# cromford-sandbox-linear (23) made 19 keys of 65-68 chars and turned main red
# (tests/lanes-registry-test.sh section 9). tests/load-project-name-length-test.sh
# keeps this number in step with catalog/lanes.json. Checked before any write.
MAX_PROJECT_LEN=19
PROJECT_NAME="${PROJECT:-$(basename "$SLUG" | tr '[:upper:]' '[:lower:]')}"
if [ "${#PROJECT_NAME}" -gt "$MAX_PROJECT_LEN" ]; then
  echo "REFUSED: project name '$PROJECT_NAME' has ${#PROJECT_NAME} chars; the limit is $MAX_PROJECT_LEN (settings keys must fit 64)."
  echo "pass a shorter --project <name>. nothing was written."
  exit 2
fi
# <<< project name length

# >>> readiness gate
# BEFORE the first anything. Below this point the command appends a fleet.conf
# row, renders a prompt, commits, pushes, creates a label and bootstraps a box —
# and a repo refused halfway through that is worse off than a repo nobody
# touched: the registry row is what cron reads, so a row whose box never
# bootstrapped is a lane that looks alive and builds nothing. So the gate runs
# before `gh` is called even once, and a refusal leaves the checkout, the
# registry and the box exactly as it found them.
#
# Default 0 = the whole block is skipped, which is what makes this flag free for
# every project already loaded without it.
if [ "${REQUIRE_READINESS:-0}" != 0 ]; then
  case "$REQUIRE_READINESS" in
    ''|*[!0-9]*) echo "load-project: --require-readiness takes a whole number (got '$REQUIRE_READINESS')"; exit 2 ;;
  esac
  # The ceiling is the level table's, not this script's. `--print-levels` reads
  # the same catalog the grading run resolves and asks GitHub nothing, so adding
  # a level 6 to catalog/readiness-levels.json makes `--require-readiness 6`
  # work without editing this file. 5 is the documented fallback for a box whose
  # catalog cannot be read at all.
  RMAX=$("$ROOT/bin/readiness-report.sh" --print-levels 2>/dev/null | jq -r '.max_level // empty') || RMAX=""
  case "$RMAX" in ''|*[!0-9]*) RMAX=5 ;; esac
  [ "$REQUIRE_READINESS" -le "$RMAX" ] \
    || { echo "load-project: --require-readiness takes a whole number 0-$RMAX (got '$REQUIRE_READINESS')"; exit 2; }
  # No clone here on purpose: onboarding has no checkout of the target repo, and
  # a gate that cloned would make a refusal depend on the network. The operator
  # grades a checkout they already have.
  [ -n "$REPO_DIR" ] \
    || { echo "load-project: --require-readiness $REQUIRE_READINESS needs --repo-dir <checkout> — this command has no clone of $SLUG to grade"; exit 2; }
  [ -d "$REPO_DIR" ] \
    || { echo "load-project: --repo-dir $REPO_DIR is not a directory"; exit 2; }
  echo "== readiness =="
  # ONE grading run, and the human and the decision read the same one. Two runs
  # would ask GitHub the same read-only questions twice AND let the table the
  # operator reads disagree with the level the gate acted on — a gate that says
  # REFUSED under a table showing the bar was met is unarguable-with.
  # stderr is deliberately NOT swallowed: when grading fails, the report's own
  # message (unreadable level table, bad $READINESS_TEST_TIMEOUT) is the only
  # thing that says why.
  RJSON=$("$ROOT/bin/readiness-report.sh" "$REPO_DIR" --json --no-run) || RJSON=""
  # The checkout must BE the repo being enrolled. --repo-dir is a path the
  # operator types, and a level graded from a sibling checkout says nothing
  # about $SLUG — the gate would print "level 4 >= 4 — continuing" under a
  # number computed for another repo, and enrol on it. The report resolves the
  # graded checkout's own origin remote; an empty slug (not a repo root, or no
  # github.com origin — every fixture) still grades, because refusing those
  # would be the gate deciding it can only ever be pointed at a clone.
  RSLUG=$(printf '%s' "$RJSON" | jq -r '.slug // ""' 2>/dev/null) || RSLUG=""
  if [ -n "$RSLUG" ] && [ "$RSLUG" != "$SLUG" ]; then
    echo "REFUSED: --repo-dir $REPO_DIR is a checkout of $RSLUG, not $SLUG"
    echo "point --repo-dir at a clone of $SLUG, or drop --require-readiness."
    echo "nothing was written: no fleet.conf row, no prompt, no commit, no box."
    exit 2
  fi
  RLEVEL=$(printf '%s' "$RJSON" | jq -r '.level // empty' 2>/dev/null) || RLEVEL=""
  case "$RLEVEL" in
    ''|*[!0-9]*) echo "REFUSED: could not grade $REPO_DIR — bin/readiness-report.sh produced no level"; exit 3 ;;
  esac
  # The operator still sees every check, rendered from the OBJECT THAT DECIDES
  # rather than from a second run of the report. This is the gate's own summary
  # of schema-1 JSON, not a copy of the report's table: a field the report adds
  # later goes unshown here, which is a thinner terminal, never a wrong verdict.
  printf '%s\n' "readiness: $REPO_DIR" "levels:    $(printf '%s' "$RJSON" | jq -r .levels_source)" ""
  printf '%s' "$RJSON" | jq -r '.checks[] | "\(.id)\t\(.status)\t\(.detail)"' \
    | while IFS=$'\t' read -r RID RST RDET; do printf '%-26s %-8s %s\n' "$RID" "$RST" "$RDET"; done
  echo "READINESS LEVEL: $RLEVEL/$(printf '%s' "$RJSON" | jq -r .max_level)"
  if [ "$RLEVEL" -lt "$REQUIRE_READINESS" ]; then
    echo "REFUSED: $SLUG grades readiness level $RLEVEL, --require-readiness $REQUIRE_READINESS"
    echo "close these first:"
    printf '%s' "$RJSON" | jq -r --argjson n "$REQUIRE_READINESS" \
      '.gaps[] | select(.level <= $n) | "  level \(.level)  \(.check)  \(.status)  \(.detail)"'
    echo "nothing was written: no fleet.conf row, no prompt, no commit, no box."
    exit 3
  fi
  echo "readiness gate: level $RLEVEL >= $REQUIRE_READINESS — continuing"
fi
# <<< readiness gate

command -v gh_auth_for >/dev/null 2>&1 && gh_auth_for "$SLUG" || true

echo "== validate repo =="
gh repo view "$SLUG" --json name,defaultBranchRef,isArchived \
  --jq 'if .isArchived then error("repo is archived") else . end' >/dev/null
[ -n "$BASE" ] || BASE=$(gh repo view "$SLUG" --json defaultBranchRef --jq .defaultBranchRef.name)
[ -n "$PROJECT" ] || PROJECT=$(basename "$SLUG" | tr '[:upper:]' '[:lower:]')
if [ -z "$PREFIX" ]; then
  # initials of the project name segments: project-11 -> RA, project-16 -> SL
  PREFIX=$(echo "$PROJECT" | awk -F- '{for(i=1;i<=NF;i++) printf toupper(substr($i,1,1))}')
  [ ${#PREFIX} -ge 2 ] || PREFIX=$(echo "$PROJECT" | cut -c1-2 | tr '[:lower:]' '[:upper:]')
fi
PREFIX_LC=$(echo "$PREFIX" | tr '[:upper:]' '[:lower:]')
echo "project=$PROJECT slug=$SLUG base=$BASE prefix=$PREFIX box=$BOX prod=$PROD"

# >>> tracker rows (BH-7924) -- before the registry row and the prompt render
# (which reads tracker_kind, BH-8450). The adapter row goes last.
if [ -n "$TRACKER" ]; then
  echo "== tracker rows =="
  if [ "$TRACKER" = linear ]; then TRK_ROWS="tracker_linear.$PROJECT.team"
  else TRK_ROWS="tracker_jira.$PROJECT.write_projects tracker_jira.$PROJECT.read_projects tracker_jira.$PROJECT.comment_projects"; fi
  for TRK_ROW in $TRK_ROWS "tracker_adapter.$PROJECT"; do
    TRK_VAL="$PREFIX"; [ "$TRK_ROW" = "tracker_adapter.$PROJECT" ] && TRK_VAL="$TRACKER"
    bin/jobs-client.sh setting-set "$TRK_ROW" "$TRK_VAL" "load-project --tracker $TRACKER" >/dev/null \
      || { echo "FATAL: could not write the settings row $TRK_ROW (bin/jobs-client.sh setting-set) — no registry row, no prompt, no commit"; exit 1; }
    echo "settings: $TRK_ROW=$TRK_VAL"
  done
fi
# <<< tracker rows

# A failure after the tracker rows names them: they stay until a re-run.
_trk_left() { [ -n "$TRACKER" ] && echo "FATAL: the tracker rows above stay written (tracker_adapter.$PROJECT and its $TRACKER rows); re-run this command to finish, or delete them"; return 0; }

obs_register || { _trk_left; exit 1; }

_obs_prompt_render || { _trk_left; exit 1; }

if [ "$FLY" = 1 ]; then
  echo "== fly onboarding queue =="
  # The QUEUE LINE RIDES THIS COMMIT on purpose (BH-662). Onboarding runs on the
  # hub, this command usually runs on a Mac, and there is no ssh between them —
  # so the repo is the channel: the line lands with the registry row, reaches
  # the hub on its next bin/fleet-propagate.sh tick (*/5), and bin/fly-pool-tick.sh
  # (*/2) drains it there. Nothing here talks to Fly.
  if grep -qE "^$PROJECT([[:space:]]|$)" "$QUEUE" 2>/dev/null; then
    echo "$QUEUE already carries $PROJECT — skipping"
  else
    printf '%s %s\n' "$PROJECT" "$(date -u +%FT%TZ)" >> "$QUEUE"
    echo "$QUEUE: queued $PROJECT for Fly builder-pool onboarding"
  fi
fi

_obs_prompt_publish || exit 1

if [ "$FLY" = 1 ]; then
  cat <<FLYQ

== fly onboarding queued ==
$QUEUE now carries '$PROJECT' (in commit $(git rev-parse --short HEAD)). The hub receives it on its
next bin/fleet-propagate.sh tick (*/5) and bin/fly-pool-tick.sh (*/10) runs bin/fly-onboard.sh $PROJECT there.
Check on the hub:  grep 'FLY_ONBOARD $PROJECT' /root/harness/logs/fly-pool-rollout.log
                   /root/harness/bin/free-slots.sh $PROJECT    -> 'unlimited (fly-routed: ...)' when done
A failure lands as one [fly-onboard] line in /root/harness/logs/ALERTS.log naming the step.
FLYQ
fi

obs_label || exit 1

if [ "$VMAP_TICKET" = 1 ]; then
  echo "== verification-map ticket =="
  # The initial producer of docs/verification-map/ is a normal ai-build ticket,
  # planned and reviewed like any other change — the harness never writes a map
  # into a repo it has not opened. Body: docs/VMAP-BACKFILL-TICKET.md, from the
  # first '---' on (everything above it is instructions to the human filing it).
  # ONE ticket per repo: an onboarding command re-run must not stack duplicates.
  VTITLE="verification map: explore the app and draft docs/verification-map/"
  # Exact title match over the listing, not `--search`: GitHub search tokenizes
  # and stems, so it both misses (indexing lag on a just-created issue) and
  # over-matches — and either error here means a duplicate ticket on someone's
  # board or a silently skipped one.
  # --limit: the dedup window. Past it the listing simply omits the existing
  # ticket and this files a duplicate on a client board with no error. Raised
  # from 300 alongside the arch flag below — same inherited bug, both lanes.
  # >>> vmap-ticket dedup
  # Read the listing into a variable FIRST, then test it. `gh ... | grep -qxF`
  # under pipefail read a PRESENT ticket as absent: grep -q exits at the match,
  # gh still has titles to write, dies of SIGPIPE, and pipefail hands the
  # pipeline 141 — so a long board filed a DUPLICATE ticket (BH-806).
  VT_RC=0
  VTITLES=; LT=$(mktemp) || VT_RC=75
  if [ "$VT_RC" -eq 0 ]; then
    gh_rest_issue_list "$SLUG" all "" 1000 > "$LT" || VT_RC=$?
    [ "$VT_RC" -ne 0 ] || VTITLES=$(jq -r '.[].title' "$LT") || VT_RC=$?
  fi
  rm -f "$LT"
  if [ "$VT_RC" -ne 0 ]; then
    echo "WARN: could not list issues on $SLUG (rc=$VT_RC) - cannot prove the verification-map ticket absent; not filing"
  elif grep -qxF "$VTITLE" <<<"$VTITLES"; then
    echo "verification-map ticket already exists on $SLUG — skipping"
  else
    VBODY=$(mktemp); trap 'rm -f "$VBODY"' EXIT
    awk 'seen{print} /^---$/ && !seen{seen=1}' docs/VMAP-BACKFILL-TICKET.md \
      | sed -e "s|<PROJECT>|$PROJECT|g" -e "s|<REPO_SLUG>|$SLUG|g" > "$VBODY"
    if [ -s "$VBODY" ]; then
      gh issue create -R "$SLUG" --title "$VTITLE" --label ai-build --body-file "$VBODY" \
        && echo "verification-map ticket filed" \
        || echo "WARN: could not file the verification-map ticket — file it by hand from docs/VMAP-BACKFILL-TICKET.md"
    else
      echo "WARN: docs/VMAP-BACKFILL-TICKET.md yielded an empty body — nothing filed"
    fi
  fi
  # <<< vmap-ticket dedup
fi

# --- ARCH TICKET (begin) ---
if [ "${ARCH_TICKET:-0}" = 1 ]; then
  echo "== agent-architecture ticket =="
  # Same shape and the same reasoning as the verification-map ticket above: the
  # harness never writes AGENT_ARCHITECTURE.md into a repo it has not read — a
  # contract assembled without reading the code describes the directory tree,
  # not the invariants, and a stated invariant that does not hold is worse than
  # no contract because everything downstream is written as if it did.
  # Body: docs/ARCH-AUDIT-TICKET.md, from the first '---' on (everything above
  # it is instructions to the human filing it by hand).
  ATITLE="agent architecture: audit the repo and draft AGENT_ARCHITECTURE.md"
  # ONE ticket per repo, matched EXACTLY against the listing. Not `--search`:
  # GitHub's index tokenizes, stems, and lags a just-created issue, so it both
  # over-matches and misses — and either error puts a duplicate on someone's
  # board or silently skips a repo that never got its ticket.
  #
  # THE LIMIT IS THE DEDUP WINDOW. An inherited 300 was already inside
  # project-2's reach, and a repo past the window returns a page that simply
  # does not contain the existing ticket — so the dedup reads "absent" and files
  # a duplicate, silently. 1000 buys room; it does not make the failure mode go
  # away, it moves it. A repo that outgrows this needs a real cursor walk.
  # >>> arch-ticket dedup
  # Same shape as the vmap probe above, and the same reason: a listing read
  # through `| grep -q` under pipefail reports a ticket that IS there as absent
  # (BH-806), and a listing that FAILED is not evidence of absence either.
  AT_RC=0
  ATITLES=; LT=$(mktemp) || AT_RC=75
  if [ "$AT_RC" -eq 0 ]; then
    gh_rest_issue_list "$SLUG" all "" 1000 > "$LT" || AT_RC=$?
    [ "$AT_RC" -ne 0 ] || ATITLES=$(jq -r '.[].title' "$LT") || AT_RC=$?
  fi
  rm -f "$LT"
  if [ "$AT_RC" -ne 0 ]; then
    echo "WARN: could not list issues on $SLUG (rc=$AT_RC) - cannot prove the agent-architecture ticket absent; not filing"
  elif grep -qxF "$ATITLE" <<<"$ATITLES"; then
    echo "agent-architecture ticket already exists on $SLUG — skipping"
  else
    # No EXIT trap for this temp file: the vmap block above already installed
    # one, and a second `trap ... EXIT` REPLACES it rather than adding to it,
    # which would leak that block's tempfile. Removed inline instead.
    ABODY=$(mktemp)
    awk 'seen{print} /^---$/ && !seen{seen=1}' docs/ARCH-AUDIT-TICKET.md \
      | sed -e "s|<PROJECT>|$PROJECT|g" -e "s|<REPO_SLUG>|$SLUG|g" > "$ABODY"
    if [ -s "$ABODY" ]; then
      gh issue create -R "$SLUG" --title "$ATITLE" --label ai-build --body-file "$ABODY" \
        && echo "agent-architecture ticket filed" \
        || echo "WARN: could not file the agent-architecture ticket — file it by hand from docs/ARCH-AUDIT-TICKET.md"
    else
      echo "WARN: docs/ARCH-AUDIT-TICKET.md yielded an empty body — nothing filed"
    fi
    rm -f "$ABODY"
  fi
  # <<< arch-ticket dedup
fi
# --- ARCH TICKET (end) ---

if [ "$BOOTSTRAP" = 0 ]; then echo "== done (bootstrap skipped) =="; exit 0; fi

obs_box || exit $?

echo
echo "== LOADED: $PROJECT =="
echo "hand it work: label an issue 'ai-build' on $SLUG (or use the /harness skill to file a plan)"
echo
# Browser QA wiring (BH-6254). project-6-os enrolled here and merged 47+ PRs with
# no vercel.conf row, prod `-`, no QA account and deploy kind `none`, so no
# browser QA ran and nothing said so. Never fatal: the `||` keeps the exit code.
# >>> browser QA (BH-6254) -- tests/load-project-qa-wiring.bh-6254-test.sh runs this block
echo "== browser QA =="
bin/qa-wiring-check.sh "$PROJECT" || echo "browser QA is not wired for $PROJECT. Fix each OWED line above (docs/onboarding-a-repo.md, 'Wire browser QA'). The daily qa-wiring-sweep lane alerts until it is fixed."
echo
# <<< browser QA
# ── THE DOORBELL (2026-09-16) ────────────────────────────────────────────────
# Onboarding used to end here, and cromford is what that cost. docs/EVENTS.md
# 4.3 designed the webhook as ONE ORG-LEVEL hook and told everyone there was
# "no per-repo bookkeeping to keep in sync with fleet.conf" -- but org hooks 403
# for our PAT, so what production actually runs is a per-repo hook, armed once
# by hand over the eight repos that existed on 2026-09-12. This command onboarded
# cromford on 2026-09-15 into the registry, the prompt and five cron lines,
# and into no doorbell at all. It produced ZERO wakes, bin/triage-gate.sh braked
# every tick to "SKIP queue-unchanged" (45m), and its only intake became
# bin/orphan-reconcile.sh's 5-per-tick safety net -- 76 open ai-build issues
# against 2 open PRs, with nothing anywhere saying why.
#
# So the last thing onboarding does is ASK, every time. It cannot ARM: the hook
# carries config[secret], whose value has two homes by design (the Cloudflare
# worker secret and the hook itself) and is in no env file this script can read.
# Never fatal -- a project with its registry row, prompt and crons is loaded, and
# a detector that can fail an onboarding is one people stop running.
# >>> doorbell banner (BH-4058) -- tests/load-project-events.bh-4058-test.sh runs this block
echo "== doorbell =="
if bin/doorbell-coverage-check.sh --repo "$SLUG" --strict; then
  :
else
  # Quoted delimiter: this block is full of backticks, backslashes and dollar
  # signs that are DATA (they are the command a human retypes), and an
  # unquoted here-doc eats all three -- it ran `wakes` as a command and folded
  # the gh continuation lines into one. $SLUG is filled in afterwards.
  sed "s|@SLUG@|$SLUG|g" <<'BANNER'
======================================================================
  DOORBELL NOT ARMED ON @SLUG@ -- THIS PROJECT IS EVENT-BLIND.

  No webhook means no "wakes" rows, so bin/triage-gate.sh brakes every
  triage tick to "SKIP queue-unchanged" (45 minutes, 4-hour backstop)
  and bin/orphan-reconcile.sh's 5-tickets-per-tick safety net is the
  ONLY intake this project gets. It will look slow, not broken.

  Arm it (operator pastes the secret -- docs/EVENTS.md 4.2/4.3):
    gh api -X POST /repos/@SLUG@/hooks -f name=web -F active=true \
      -f 'config[url]=<JOBS_URL>/webhooks/github' \
      -f 'config[content_type]=json' -f 'config[insecure_ssl]=0' \
      -f 'config[secret]=<the worker GITHUB_WEBHOOK_SECRET>' \
      -f 'events[]=pull_request'  -f 'events[]=pull_request_review' \
      -f 'events[]=check_suite'   -f 'events[]=check_run' \
      -f 'events[]=push'          -f 'events[]=deployment_status' \
      -f 'events[]=issues'        -f 'events[]=issue_comment' \
      -f 'events[]=status'        -f 'events[]=workflow_run' \
      -f 'events[]=merge_group'

  Verify:  bin/doorbell-coverage-check.sh --repo @SLUG@
======================================================================
BANNER
fi
# <<< doorbell banner
echo
# Not "optional env" in a trailing list — a missing bypass secret does not fail
# loudly, it silently makes EVERY pr tier-2 forever, because preview QA cannot
# reach an SSO-protected deployment and an unverified build never earns tier 1.
# Generating it here would need a Vercel token AND the project id, neither of
# which this command has, so it says the one thing a human must do.
cat <<BANNER
======================================================================
  VERCEL-HOSTED REPO? SET THE PREVIEW BYPASS SECRET.

  Without VERCEL_AUTOMATION_BYPASS_SECRET in env/$PROJECT.env, preview QA
  gets Vercel's SSO wall instead of the app, so every PR lands as TIER 2
  and waits on a human -- quietly, with no error anywhere.

  Get it:  Vercel project -> Settings -> Deployment Protection ->
           Protection Bypass for Automation -> Add Secret
  Put it:  ssh root@$BOX, then append it to env/$PROJECT.env (chmod 600)
======================================================================
BANNER
echo "other optional env on $BOX in env/$PROJECT.env: DEPLOY_HOOK_URL (QA_* is required: see == browser QA == above)"
command -v gh_auth_reset >/dev/null 2>&1 && gh_auth_reset || true
