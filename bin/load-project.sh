#!/bin/bash
# load-project.sh — onboard a repo into the harness fleet in one command.
#
#   load-project.sh <owner/repo> [--project <name>] [--prod <url>] [--box <host>]
#                   [--prefix <KEY>] [--base <branch>] [--context <file>]
#                   [--no-bootstrap] [--vmap-ticket] [--arch-ticket] [--fly]
#                   [--require-readiness <n>] [--repo-dir <checkout>]
#
# What it does (idempotent — re-running skips what exists):
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

SLUG="${1:?usage: load-project.sh <owner/repo> [--project name] [--prod url] [--box host] [--prefix KEY] [--base branch] [--context file] [--no-bootstrap] [--require-readiness <n> --repo-dir <checkout>]}"
shift
# BH-4080: the default box name and the harness repo the box clones live in
# the deployment defaults home.
# shellcheck source=bin/lib/deployment.sh
. "${HARNESS_DEPLOYMENT_FILE-$ROOT/bin/lib/deployment.sh}"
PROJECT="" PROD="-" BOX="${HARNESS_BOX_PREFIX}small" PREFIX="" BASE="" CONTEXT_FILE="" BOOTSTRAP=1 VMAP_TICKET=0 ARCH_TICKET=0 FLY=0
QUEUE="fly/onboard-queue.conf"
REQUIRE_READINESS=0 REPO_DIR=""
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
    *) echo "unknown flag $1"; exit 2 ;;
  esac
done

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

echo "== registry =="
export FLEET_CONF="$ROOT/fleet.conf"
# REGISTRY_SOURCE=db (BH-5650): the D1 registry is what every reader sees, so
# the row goes THERE. A fleet.conf append in db mode would be a row no
# fleet-conf.sh call returns, committed as if it were the registry. The two
# reads below need no branch: fleet-conf.sh and box-for.sh read the registry in
# db mode already. Anything but exactly "db" is file mode, as in fleet-conf.sh.
REG_MODE=file
if [ "${REGISTRY_SOURCE:-}" = db ]; then REG_MODE=db; fi
if bin/fleet-conf.sh "$PROJECT" repo >/dev/null 2>&1; then
  echo "fleet.conf row exists — skipping"
  OFF=$(bin/fleet-conf.sh "$PROJECT" offset)
else
  # Free cron-offset minute (0-9) among projects on the SAME box; least-used if full.
  USED=$(for pj in $(bin/fleet-conf.sh --projects); do
    [ "$(bin/box-for.sh "$pj" 2>/dev/null)" = "$BOX" ] && bin/fleet-conf.sh "$pj" offset || true; done)
  OFF=""
  for cand in 1 3 5 7 0 2 4 6 8 9; do
    grep -qx "$cand" <<<"$USED" || { OFF=$cand; break; }
  done
  [ -n "$OFF" ] || OFF=$(sort <<<"$USED" | uniq -c | sort -n | awk 'NR==1{print $2}')
  if [ "$REG_MODE" = db ]; then
    # No token = no write, and NO fallback append: the reader would not see it.
    [ -n "${REGISTRY_ADMIN_TOKEN:-}" ] \
      || { echo "FATAL: REGISTRY_SOURCE=db and REGISTRY_ADMIN_TOKEN is unset — cannot write the registry row for $PROJECT; nothing written"; exit 1; }
    bin/registry.sh add-project "$PROJECT" --repo "$SLUG" --prod "$PROD" --offset "$OFF" --box "$BOX" \
      || { echo "FATAL: bin/registry.sh add-project $PROJECT failed (above) — no prompt, no commit"; exit 1; }
    # TTL 0: the 60 s cache was filled by the reads above, without this row.
    REGISTRY_CACHE_TTL_S=0 bin/fleet-conf.sh "$PROJECT" offset >/dev/null \
      || { echo "FATAL: the registry row for $PROJECT did not read back — not committing"; exit 1; }
    echo "registry: added ($PROJECT offset=$OFF box=$BOX)"
  else
    # A registry whose last byte is not "\n" GLUES the new row onto the last one
    # and publishes it (harness-console onto cromford, 2026-09-16, hand-split
    # in 00a9911): the old row's box column grew a project name, the new project
    # had no row at all, and the push went out green.
    [ ! -s fleet.conf ] || [ -z "$(tail -c1 fleet.conf)" ] || echo >> fleet.conf
    # The 7th column is the box's tailnet address. A box the registry already
    # knows gets it (project-6-desktop, 8a1d9bc7c: a 6-column row on small made
    # box-register refuse "box small already has the address -"). A new box has
    # none yet, so its row stays at 6 columns until box-register sets it.
    BOX_IP=$(bin/fleet-conf.sh --tailnet-ip-of-box "$BOX" 2>/dev/null) || BOX_IP=""
    printf '%-13s %-26s %-36s %-3s %-2s %s%s\n' "$PROJECT" "$SLUG" "$PROD" "-" "$OFF" "$BOX" "${BOX_IP:+ $BOX_IP}" >> fleet.conf
    # Read the row back through the same parser every lane uses, BEFORE the commit
    # step below can publish it. This is the one check that would have stopped
    # 00a9911's row from reaching main.
    bin/fleet-conf.sh "$PROJECT" offset >/dev/null \
      || { echo "FATAL: fleet.conf row for $PROJECT did not parse back — not committing"; exit 1; }
    echo "fleet.conf: added ($PROJECT offset=$OFF box=$BOX)"
  fi
fi

echo "== prompt =="
if [ -f "prompts/$PROJECT.md" ]; then
  echo "prompts/$PROJECT.md exists — skipping"
else
  CONTEXT=""
  [ -n "$CONTEXT_FILE" ] && CONTEXT=$(cat "$CONTEXT_FILE")
  export CONTEXT
  python3 - "$PROJECT" "$SLUG" "$PROD" "$PREFIX" "$PREFIX_LC" "$BASE" <<'PY'
import sys, os
project, slug, prod, prefix, prefix_lc, base = sys.argv[1:7]
t = open('prompts/TEMPLATE-GH.md').read()
# drop the template header note
lines = t.split('\n')
lines[0] = f'# Triage run — {project} (GitHub Issues board)'
t = '\n'.join(lines)
ctx = os.environ.get('CONTEXT','').strip()
t = t.replace('<CONTEXT>', ctx if ctx else '')
for a,b in [('<PROJECT>',project),('<REPO_SLUG>',slug),('<PROD_URL>',prod),
            ('<KEY_PREFIX_LC>',prefix_lc),('<key_prefix_lc>',prefix_lc),
            ('<KEY_PREFIX>',prefix),('<BASE_BRANCH>',base)]:
    t = t.replace(a,b)
open(f'prompts/{project}.md','w').write(t)
PY
  echo "prompts/$PROJECT.md rendered"
fi

echo "== crontab =="
# THE CRONTAB IS NO LONGER A COMMITTED ARTIFACT (BH-1247). This block used to
# regenerate cron/<box-id>.cron and publish it in the SAME commit as the
# fleet.conf row, because a row published without a regenerated cron file was a
# lane the next 05:17 tick quietly deleted — that is how project-7 died ten
# hours after it was loaded.
#
# The render is produced on the box now, by bin/render-crontab.sh, from the
# registry plus the fragments. So the fleet.conf row IS the whole of onboarding
# and the second step cannot be forgotten: there is no file left to forget to
# regenerate. What is still worth doing here is SHOWING the operator the lines
# this box will gain — rendered into a temp file, never into the tree.
# shellcheck source=bin/lib/cron-lines.sh
. bin/lib/cron-lines.sh
BOX_ID=$(cron_box_id_for "$BOX")
CRON_PREVIEW=$(mktemp)
trap 'rm -f "$CRON_PREVIEW"' EXIT
if bin/render-crontab.sh "$BOX_ID" > "$CRON_PREVIEW" 2>/dev/null && [ -s "$CRON_PREVIEW" ]; then
  LINES=$(grep -c -- "$PROJECT" "$CRON_PREVIEW" 2>/dev/null) || LINES=0
  echo "cron/$BOX_ID.cron renders $LINES line(s) for $PROJECT (generated on the box, not committed):"
  grep -- "$PROJECT" "$CRON_PREVIEW" | sed 's/^/    /' || true
  [ "$LINES" -gt 0 ] || echo "WARN: the render carries NO line for $PROJECT — check the fleet.conf row and bin/box-for.sh"
else
  echo "WARN: bin/render-crontab.sh $BOX_ID would not render — the box would keep its current crontab."
  echo "      Run it by hand and read the error before relying on this onboarding."
fi
rm -f "$CRON_PREVIEW"
# Released immediately: the vmap block below installs its own EXIT trap, and a
# second `trap ... EXIT` REPLACES rather than adds (that hazard is already
# commented there). Leaving this one armed would make the interaction depend on
# which block runs first.
trap - EXIT

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

echo "== commit + push =="
# cron/<box>.cron is NOT in this list any more (BH-1247): it is generated on the
# box and git-ignored, so there is nothing to diff, nothing to stage, and
# nothing that can be forgotten. What onboarding commits is the fleet.conf row
# and the prompt — and the row alone is now enough to keep the lane alive,
# which is the property the cron regeneration used to buy by hand.
# In db mode the row is already in the registry (BH-5650), so fleet.conf is out
# of the diff check and out of `git add`: a stray local edit to it must not ride
# an onboarding commit. The prompt still commits — code stays in PRs.
COMMIT_PATHS=(fleet.conf "prompts/$PROJECT.md")
if [ "$REG_MODE" = db ]; then COMMIT_PATHS=("prompts/$PROJECT.md"); fi
if ! git diff --quiet -- "${COMMIT_PATHS[@]}" 2>/dev/null \
   || [ -n "$(git status --porcelain -- "${COMMIT_PATHS[@]}")" ] \
   || { [ "$FLY" = 1 ] && [ -n "$(git status --porcelain -- "$QUEUE")" ]; }; then
  git add "${COMMIT_PATHS[@]}"
  # Staged only under --fly, so the default path stages exactly what it staged
  # before this flag existed.
  if [ "$FLY" = 1 ]; then git add "$QUEUE"; fi
  git commit -q -m "load-project: $PROJECT ($SLUG) on $BOX

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
fi
# Publish MUST land before the box syncs — verify, don't assume (a refused
# rebase or rejected push here left a box bootstrapping against a registry
# that didn't have the project, 2026-08-18).
git pull --rebase --autostash -q || { echo "FATAL: rebase failed — resolve and re-run"; exit 1; }
git push -q || { echo "FATAL: push failed — resolve and re-run"; exit 1; }
git fetch -q origin
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main 2>/dev/null || git rev-parse origin/HEAD)" ] \
  || { echo "FATAL: origin does not match HEAD after push"; exit 1; }
echo "published $(git rev-parse --short HEAD)"

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

echo "== ai-build label =="
gh label create ai-build -R "$SLUG" --color 1D76DB \
  --description "Harness-buildable: the board watcher acts on this" 2>/dev/null \
  && echo "label created" || echo "label exists"

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

echo "== box: $BOX =="
# Run the block LOCALLY when the target box IS this machine. Loading project-7
# from the project-6 box itself tried `ssh root@box-project-6-1`, which
# is a tailnet name the box does not resolve for ITSELF: the ssh died with
# "Could not resolve hostname", so the runtime fleet.conf was never synced and
# the env stub was never written — and because the failure was at the very last
# step it read as "nearly done" rather than "not done".
RUN_ON_BOX=(ssh -o ConnectTimeout=15 "root@$BOX" bash -s --)
if [ "$BOX" = "$(hostname 2>/dev/null)" ] \
   || { [ -r /root/harness/state/box-id ] && [ "$(cron_box_id_for "$BOX")" = "$(cat /root/harness/state/box-id)" ]; }; then
  echo "target box is THIS machine — running the bootstrap block locally, not over ssh"
  RUN_ON_BOX=(bash -s --)
fi
BOOT_RC=0
"${RUN_ON_BOX[@]}" "$PROJECT" "$PROD" "$PREFIX" "$BASE" "$HARNESS_REPO" "$REG_MODE" <<'REMOTE' || BOOT_RC=$?
set -euo pipefail
PROJECT="$1"; PROD="$2"; PREFIX="$3"; BASE="$4"; HREPO="$5"
# The registry mode (BH-5650). Absent (an older caller) = file.
REG_MODE="${6:-file}"
if [ "$REG_MODE" = db ]; then export REGISTRY_SOURCE=db; fi
. /root/harness/bin/lib/env-path.sh 2>/dev/null || harness_env_dir() { printf '%s\n' /root/harness/env; }; E=$(harness_env_dir)
# Preconditions: a provisioned fleet box (see docs/OPERATOR-SETUP.md).
[ -f "$E/global.env" ] || { echo "FATAL: $E/global.env missing — provision the box first"; exit 1; }
# C2: the box's GitHub credential is bin/gh-token.sh's answer (the App, then its
# PAT ladder: env/global.env, env/gh-pat). A keyring login is only the fallback —
# the fleet is logging it out, and it is the operator's PAT where it still exists.
_gt=""
[ -x /root/harness/bin/gh-token.sh ] && _gt=$(/root/harness/bin/gh-token.sh "$HREPO" 2>/dev/null || true)
if [ -z "$_gt" ] && ! gh auth status >/dev/null 2>&1; then
  echo "FATAL: no GitHub credential on box — /root/harness/bin/gh-token.sh $HREPO printed nothing (check env/github-app.env + .pem, or env/gh-pat) and gh has no keyring login"; exit 1
fi
unset _gt
# Sync the fresh checkout into the runtime.
# The clone below is a different repo from $SLUG, so it arms again — and this
# block runs ON THE BOX, where the lib is absent until the box's first sync.
[ -r /root/harness/bin/lib/gh-app-auth.sh ] && . /root/harness/bin/lib/gh-app-auth.sh || true
command -v gh_auth_for >/dev/null 2>&1 && gh_auth_for "$HREPO" || true
if [ -d /root/harness-checkout/.git ]; then
  git -C /root/harness-checkout pull --ff-only -q
else
  gh repo clone "$HREPO" /root/harness-checkout -- -q
fi
# In db mode the row is in the registry, not in the checkout's fleet.conf, and
# bootstrap-machine.sh below reads it there (REGISTRY_SOURCE exported above).
if [ "$REG_MODE" != db ]; then
  grep -qE "^$PROJECT[[:space:]]" /root/harness-checkout/fleet.conf \
    || { echo "FATAL: $PROJECT not in the box checkout's fleet.conf — was the publish step green?"; exit 1; }
fi
[ -f "/root/harness-checkout/prompts/$PROJECT.md" ] \
  || { echo "FATAL: prompts/$PROJECT.md missing in the box checkout"; exit 1; }
mkdir -p /root/harness
if [ -x /root/harness/bin/harness-sync.sh ]; then
  /root/harness/bin/harness-sync.sh || true
else
  cp -r /root/harness-checkout/bin /root/harness/
  cp -r /root/harness-checkout/prompts /root/harness/
  if [ "$REG_MODE" != db ]; then cp /root/harness-checkout/fleet.conf /root/harness/fleet.conf; fi
  for d in catalog rules; do [ -d "/root/harness-checkout/$d" ] && cp -r "/root/harness-checkout/$d" /root/harness/; done
fi
# Env stub (GitHub-Issues board: no app token needed; PROD may be "-").
# The sync above must have actually landed the prompt (rsync missing on a
# fresh box made it fail silently once — 2026-08-18).
[ -f "/root/harness/prompts/$PROJECT.md" ] \
  || { echo "FATAL: /root/harness/prompts/$PROJECT.md not deployed — check rsync + harness-sync log"; exit 1; }
ENVF="$E/$PROJECT.env"
if [ ! -f "$ENVF" ]; then
  # Literal path, [ -x ]-guarded: a box that has not synced bin/ yet simply has
  # no harden-state.sh and the wrap is a no-op (a false [ -x ] on the left of &&
  # does not trip this heredoc's `set -e`). --release on a file that does not
  # exist is rc 0 and quiet; the --rearm after the write is what arms the fresh
  # stub immediately, so the box is never left with one unhardened env file.
  [ -x /root/harness/bin/harden-state.sh ] && /root/harness/bin/harden-state.sh --release "$ENVF"
  {
    echo "# $PROJECT project env — board is GitHub Issues (gh auth), no internal API token"
    echo "${PREFIX}_API_BASE=$PROD"
    echo "BASE_BRANCH=$BASE"
    echo "# optional, add when available:"
    echo "#DEPLOY_HOOK_URL="
    echo "#VERCEL_AUTOMATION_BYPASS_SECRET="
  } > "$ENVF"
  chmod 600 "$ENVF"
  [ -x /root/harness/bin/harden-state.sh ] && /root/harness/bin/harden-state.sh --rearm "$ENVF"
  echo "env stub written: $ENVF"
fi
/root/harness/bin/bootstrap-machine.sh "$PROJECT"
REMOTE
# The remote block's rc is CAPTURED rather than left to `set -e`. It propagates
# today only because that line is a bare top-level command, which one `|| true`
# or one `set +e` above it would silently undo — and the loader itself said
# nothing, so the remote FATAL scrolled past under a "== LOADED" that never came.
# The rung is stated honestly: publishing already happened, setup did not.
[ "$BOOT_RC" = 0 ] || {
  echo "FATAL: bootstrap block on $BOX exited $BOOT_RC — registry, prompt and crontab are PUBLISHED, but the box is NOT set up. Fix the FATAL above and re-run (idempotent)."
  exit "$BOOT_RC"
}

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
