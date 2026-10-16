#!/bin/bash
# bin/harness-sync.sh [--check] — make this box's harness checkout, and the live
# /root/harness copy, match ORIGIN.
#
# Why (the operator, 2026-08-14): the context gate proved a box's live rules/bin matched
# its OWN checkout. Nothing proved the checkout matched the repo. The checkout
# only moved once a day (update-runners, 05:17Z cron), so for up to 24 hours a
# box could pass the gate cleanly while planning, executing and reviewing under
# superseded rules, prompts and pipeline code — the same class of silent drift
# that had three boxes building client software under a 2.5KB ruleset, one level
# up. "In sync with my checkout" is only worth something if the checkout is
# current, so freshness is now verified before every build.
#
# --check   report freshness only, no writes, no network side effects beyond a
#           fetch. Exit codes:
#             0  checkout is at origin/<branch>
#            10  behind origin (fast-forwardable)
#            20  UNKNOWN — fetch failed (offline, auth, GitHub down), or there
#                is no checkout at $CHECKOUT at all
#            30  diverged, the checkout has local modifications, or the checkout
#                is NOT ON MAIN — that last one prints `refused branch=<b>` and
#                does nothing else: no stamp, no ALERTS line (see WRITTEN ONLY
#                BY THE DEPLOY PATH below). All three need a human.
#
# default   fetch, fast-forward, deploy bin/ prompts/ catalog/ fleet.conf, and
#           re-render the machine rules. One status line on stdout. Exit codes:
#             0  deployed
#            20  no checkout, another harness-sync holds the lock, freshness
#                UNKNOWN, or the ff-only pull failed after a clean freshness
#                check (that last one stamps
#                state/harness-sync-last-refused with `pull-failed`)
#            30  REFUSED — the checkout is on a side branch, diverged, or
#                locally modified; stamps the refusal and writes an ALERTS line
#           After the code copy it writes state/harness-sync-phase (`copied`,
#           `step=<name>`, `done`), and each step after the copy runs under its
#           own timeout with one `step=` line in update-runners.log; a cut step
#           never changes the exit code (BH-7122, bin/lib/harness-sync-step.sh).
#
# rsync writes temp-file+rename, so a running pipeline keeps its open inode and
# never sees a half-written script (the "never edit bin/*.sh in place" rule).
set -uo pipefail
# HARNESS_CHECKOUT overrides the checkout path for TESTS only — point it at a
# scratch clone to exercise the behind/diverged paths without moving the box's
# real checkout out from under a running build.
CHECKOUT="${HARNESS_CHECKOUT:-/root/harness-checkout}"
# HARNESS overrides the LIVE install path, for the same reason and with the same
# caveat: cron never sets it, so production resolves exactly the path it always
# has. Without it a fixture that drove the deploy path rsynced a scratch
# checkout straight over the real /root/harness — which is how this override got
# written (BH-628), and why the stamps below can be tested at all.
HARNESS="${HARNESS:-/root/harness}"
. "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$HARNESS")
# shellcheck source=bin/lib/flag-on.sh
. "$HARNESS/bin/lib/flag-on.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/flag-on.sh" 2>/dev/null || flag_file_on() { [ -f "$HARNESS/flags/$1-$2" ]; }
LOG="$HARNESS/logs/update-runners.log"
STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
# Two facts nobody was writing down, read by pipeline-health's hub-sync-stall
# check: when this box last DEPLOYED, and whether the last attempt was REFUSED.
# The refusal used to be an append-only ALERTS line and nothing else, so "the
# hub has not synced since 09:30" was not a question anything could answer —
# the drift check compares the CHECKOUT's HEAD to origin and the ff-only pull
# keeps that current while the deploy refuses (BH-628: the hub's live bin/ was
# frozen for 16h with every check green).
#
# WRITTEN ONLY BY THE DEPLOY PATH. `--check` runs before every build on every
# box in the fleet; a --check that stamped would make the whole fleet look like
# a refusing hub. And only rc 30 / pull-failed stamp a REFUSAL — a busy lock or
# a failed fetch is transient, and stamping it would page for a network blink
# followed by a quiet main.
stamp_state() { # stamp_state <basename> [reason]
  local f="$HARNESS/state/$1"
  mkdir -p "$HARNESS/state" 2>/dev/null
  { date -u '+%Y-%m-%dT%H:%M:%SZ'; [ $# -gt 1 ] && printf '%s\n' "$2"; true; } > "$f.tmp" 2>/dev/null \
    && mv "$f.tmp" "$f" 2>/dev/null
}

MODE="${1:-deploy}"
[ -d "$CHECKOUT/.git" ] || { echo "no checkout at $CHECKOUT"; exit 20; }
CUR_BRANCH=$(git -C "$CHECKOUT" branch --show-current 2>/dev/null || git -C "$CHECKOUT" rev-parse --abbrev-ref HEAD 2>/dev/null)
[ -n "$CUR_BRANCH" ] || CUR_BRANCH=HEAD
# --check on a side branch is rc 30 and NOTHING else: no stamp, no ALERTS line
# (see WRITTEN ONLY BY THE DEPLOY PATH above — context-gate runs --check before
# every build on every box). The deploy path stamps + alerts below, after the
# lock.
if [ "$CUR_BRANCH" != main ] && [ "$MODE" = "--check" ]; then
  echo "refused branch=$CUR_BRANCH"
  exit 30
fi
BRANCH=main

# Freshness, as a classification. Never guesses: a fetch that fails is UNKNOWN,
# not "fresh" — the whole point of this gate is that silence must not read as
# proof (same lesson as the QA fail-open that fed tier-1 merges).
freshness() {
  # One fetch at a time per box: parallel builds all check before starting, and
  # concurrent fetches contend on the same ref locks.
  if ! flock -w 90 "$HARNESS/locks/harness-fetch.lock" \
       timeout 60 git -C "$CHECKOUT" fetch --quiet origin "$BRANCH" 2>/dev/null; then
    echo "unknown fetch-failed"; return 20
  fi
  # Uncommitted work IN THE CHECKOUT is only a build problem when it touches what
  # shapes a build. Someone editing docs on a box must not halt its pipeline;
  # uncommitted bin/prompts/rules mean the box is running code no commit records.
  local dirty
  dirty=$(git -C "$CHECKOUT" status --porcelain --untracked-files=no 2>/dev/null \
          | awk '{print $NF}' | grep -E '^(bin/|prompts/|rules/|fleet\.conf$)' | head -3 | tr '\n' ' ')
  if [ -n "$dirty" ]; then
    echo "dirty uncommitted: ${dirty% }"; return 30
  fi
  local local_sha remote_sha base
  local_sha=$(git -C "$CHECKOUT" rev-parse HEAD 2>/dev/null)
  remote_sha=$(git -C "$CHECKOUT" rev-parse "origin/$BRANCH" 2>/dev/null)
  base=$(git -C "$CHECKOUT" merge-base HEAD "origin/$BRANCH" 2>/dev/null)
  [ -n "$local_sha" ] && [ -n "$remote_sha" ] || { echo "unknown no-ref"; return 20; }
  if [ "$local_sha" = "$remote_sha" ]; then
    echo "fresh ${local_sha:0:7}"; return 0
  elif [ "$local_sha" = "$base" ]; then
    local n; n=$(git -C "$CHECKOUT" rev-list --count "HEAD..origin/$BRANCH" 2>/dev/null || echo "?")
    echo "behind ${local_sha:0:7}->${remote_sha:0:7} ($n commits)"; return 10
  else
    echo "diverged ${local_sha:0:7} vs ${remote_sha:0:7}"; return 30
  fi
}

if [ "$MODE" = "--check" ]; then
  OUT=$(freshness); RC=$?
  echo "$OUT"
  exit $RC
fi

# --- deploy ---------------------------------------------------------------
# Serialize: update-runners (daily) and the pre-build gate can fire together.
exec 8>"$HARNESS/locks/harness-sync.lock"
flock -w 120 8 || { echo "another harness-sync holds the lock"; exit 20; }

# The branch preflight: a side-branch checkout is refused before any fetch or
# rsync, and this is the one place it is recorded (stamp + ALERTS).
if [ "$CUR_BRANCH" != main ]; then
  HARNESS="$HARNESS" "$HARNESS/bin/alert-line.sh" "harness sync REFUSED: checkout on $CUR_BRANCH, not main — the reconcile is NOT automated on purpose (a force-reset of a box checkout destroys uncommitted work); the alert medic owns this line"
  stamp_state harness-sync-last-refused "branch=$CUR_BRANCH"
  echo "refused branch=$CUR_BRANCH"
  exit 30
fi

# Install a post-checkout hook that logs moves off main. The hook belongs to
# the checkout, not the live install, so a manual branch move is recorded too.
install_post_checkout_hook() {
  local hook="$CHECKOUT/.git/hooks/post-checkout"
  # An existing hook is replaced only when it is an OLDER VERSION OF OURS. The
  # old rule was `[ -x "$hook" ] && return 0`, which froze every hub that had
  # already installed the v1 body: a fix to the hook shipped to nothing but
  # fresh checkouts (BH-1128). A hook without our marker line is hand-written
  # and is still left alone, which is what BH-1099 promised.
  if [ -e "$hook" ]; then
    grep -q 'installed by bin/harness-sync.sh' "$hook" 2>/dev/null || return 0
    grep -q 'installed by bin/harness-sync.sh (v2' "$hook" 2>/dev/null && return 0
  fi
  mkdir -p "$(dirname "$hook")" 2>/dev/null || return 0
  cat > "$hook" <<'HOOK'
#!/bin/bash
# log moves off main; installed by bin/harness-sync.sh (v2: exit 0, branch checkouts only)
new_branch=$(git symbolic-ref --short HEAD 2>/dev/null || git rev-parse --abbrev-ref HEAD 2>/dev/null)
[ "$new_branch" = main ] && exit 0
# git passes 1 for a branch checkout and 0 for a file checkout (`git checkout --
# f`, `git restore`). Only a branch move is a move off main; a file checkout on
# a side branch used to log a spurious line. A manual call with no flag at all
# is treated as a branch move.
[ "${3:-1}" = 1 ] || exit 0
h=${HARNESS:-/root/harness}
# "who", not just "when": the git process that moved it (pid + its cmdline) and
# the from/to shas git hands a post-checkout hook.
# The ref is captured on its own line rather than inline: the race-sigpipe rule
# reads `git … | head` across the whole line and cannot see that the pipe here
# belongs to `tr`, not to git (BH-1248). Same value, and the rule now stays
# quiet without a waiver to maintain.
ref=$(git rev-parse --short HEAD 2>/dev/null)
echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') checkout moved off main to $new_branch (ref $ref) pid=$PPID cmd=$(tr '\0' ' ' </proc/$PPID/cmdline 2>/dev/null | head -c 200) from=${1:0:7} to=${2:0:7}" >> "$h/logs/checkout-moves.log"
# A failed log append must never make `git checkout` fail: this hook is
# attribution, not a gate, and the hook's rc IS git's rc. Without this line a
# checkout on a box with no $HARNESS/logs returned 1, and every caller that
# reads that rc recorded a failure that did not happen.
exit 0
HOOK
  chmod +x "$hook" 2>/dev/null || true
}
install_post_checkout_hook

OUT=$(freshness); RC=$?
case "$RC" in
  20) echo "$(STAMP) harness sync: freshness UNKNOWN ($OUT) — live files untouched" >> "$LOG"
      echo "unknown ($OUT)"; exit 20 ;;
  30) HARNESS="$HARNESS" "$HARNESS/bin/alert-line.sh" "harness sync REFUSED: checkout $OUT — the reconcile is NOT automated on purpose (a force-reset of a box checkout destroys uncommitted work); the alert medic owns this line"
      stamp_state harness-sync-last-refused "$OUT"
      echo "refused ($OUT)"; exit 30 ;;
esac

BEFORE=$(git -C "$CHECKOUT" rev-parse --short HEAD 2>/dev/null)
if [ "$RC" = "10" ]; then
  git -C "$CHECKOUT" pull --ff-only --quiet 2>>"$LOG" || {
    echo "$(STAMP) harness sync: git pull failed after a clean freshness check" >> "$LOG"
    # Not transient: the freshness check already said fast-forwardable, so a
    # pull that still fails is the checkout needing a human — same condition the
    # rc 30 branch records, and the stall check should see it as a refusal.
    stamp_state harness-sync-last-refused "pull-failed"
    echo "pull-failed"; exit 20
  }
fi
AFTER=$(git -C "$CHECKOUT" rev-parse --short HEAD 2>/dev/null)

# The git-ignored doc indexes (docs/verification-map/README.md, BH-1175, and
# docs/LLM_CALL_SITES.md, BH-1268) are rebuilt by bin/docs-sync.sh, launched
# detached after the success stamp below (BH-6806, "doc indexes, detached").
# >>> context budget manifest compose (BH-6487)
# catalog/context-budgets.json is composed from catalog/context-budgets.d/ and
# no longer committed, and every runtime reader (agent-call, llm-gate, the
# budget DB sync below, cost-rollup) reads it from this checkout or from the
# $HARNESS/catalog copy the rsync below makes. A refused compose is one ALERT
# per box; the sync goes on, and the last good file stays in both places (the
# composer never writes on refusal, and the catalog rsync has no --delete).
if [ -x "$CHECKOUT/bin/context-budgets-build.sh" ] \
   && ! "$CHECKOUT/bin/context-budgets-build.sh" --compose --repo "$CHECKOUT" >>"$LOG" 2>&1; then
  HARNESS="$HARNESS" "$HARNESS/bin/alert-line.sh" --id "budgets-compose-$(hostname)" "[$(hostname)] harness sync: catalog/context-budgets.json could NOT be composed from catalog/context-budgets.d — lanes keep the last good manifest; fix the fragment bin/context-budgets-build.sh --check names (update-runners.log)"
fi
# <<< context budget manifest compose
# An already-current checkout still deploys: this is the explicit deploy command,
# and the box that authored a commit has a fresh checkout with STALE live files —
# skipping the rsync there left the hub failing its own gate (caught first run).
# rsync is a no-op when the files match, and temp+rename when they don't.

# WATCHDOG_URL seed (BH-2091): the watchdog readers are losing their hard-coded
# host, so this fleet's value is appended to env/global.env from the repo-managed
# catalog/fleet-watchdog.json first (origin-guarded; an operator's own non-empty
# line is left alone). A failed seed is one ALERTS line, never a failed deploy.
if [ -r "$CHECKOUT/bin/lib/watchdog-url.sh" ] && . "$CHECKOUT/bin/lib/watchdog-url.sh"; then
  watchdog_url_seed "$CHECKOUT" "$HENV/global.env" "$HARNESS" || true
fi
# REGISTRY_SOURCE=db seed (BH-5651): the fleet switch to the D1 registry. Only
# when env/global.env has no REGISTRY_SOURCE= line and the registry answers
# with the checkout's project set; REGISTRY_SOURCE=file there is the kill switch.
if [ -r "$CHECKOUT/bin/lib/registry-source-seed.sh" ] && . "$CHECKOUT/bin/lib/registry-source-seed.sh"; then
  registry_source_seed "$CHECKOUT" "$HENV/global.env" "$HARNESS" || true
fi

# catalog/ BEFORE bin/ (BH-1644): a new bin/lib reader must never be live
# without the registry entry that gives its knob a default.
[ -d "$CHECKOUT/catalog" ] && rsync -a "$CHECKOUT/catalog/" "$HARNESS/catalog/" 2>>"$LOG"
# agent-core/ before bin/ too: bin/staff-core.mjs imports ../agent-core/src
# relative to itself, so the package must be live before its reader (BH-5561).
[ -d "$CHECKOUT/agent-core" ] && rsync -a --delete "$CHECKOUT/agent-core/" "$HARNESS/agent-core/" 2>>"$LOG"
rsync -a "$CHECKOUT/bin/" "$HARNESS/bin/" 2>>"$LOG"
# >>> post-copy steps lib (BH-7122)
# The phase stamp, the per-step timeout and the pending deploy markers
# (bin/lib/harness-sync-step.sh has the formats). Sourced right after bin/ is
# live, so the sync that brings the lib also uses it. Without the lib each step
# runs exactly as it did before: no stamp, no step timeout, no marker.
# shellcheck source=bin/lib/harness-sync-step.sh
. "$HARNESS/bin/lib/harness-sync-step.sh" 2>/dev/null \
  || . "$(dirname "${BASH_SOURCE[0]}")/lib/harness-sync-step.sh" 2>/dev/null \
  || { hs_step() { shift 2; "$@"; }; hs_phase() { :; }; hs_pending_queue() { :; }; }
# <<< post-copy steps lib
rsync -a "$CHECKOUT/prompts/" "$HARNESS/prompts/" 2>>"$LOG"
# fly/ too: bin/fly-image-build.sh bakes fly/Dockerfile + fly/entrypoint.sh from
# the LIVE install (its own ../fly), so a fly/ change that only lands in the
# checkout is never in an image. 2026-09-11: the per-machine box-name fix (#244)
# was rebuilt twice from a stale /root/harness/fly and never took effect.
rsync -a "$CHECKOUT/fly/" "$HARNESS/fly/" 2>>"$LOG"
# checks/ is CODE the gates execute, not documentation: bin/merge-sweep.sh and
# bin/run-build.sh both run bin/checks-run.sh over a diff, and the runner
# resolves the catalog relative to itself ($HARNESS/checks on a box). Without
# this line the wiring is dead on every box — the runner ships with bin/ and
# then finds no catalog, which it reports as "could not run" forever.
# guardrails/ rides along for a smaller but real reason: bin/rule-miner.sh tells
# its drafting session to read $HARNESS/guardrails as the format and quality bar
# for a promoted check, and on 2026-08-26 that session logged "the listed
# guardrails path isn't there" and drafted no check at all.
[ -d "$CHECKOUT/checks" ] && rsync -a --delete "$CHECKOUT/checks/" "$HARNESS/checks/" 2>>"$LOG"
[ -d "$CHECKOUT/guardrails" ] && rsync -a --delete "$CHECKOUT/guardrails/" "$HARNESS/guardrails/" 2>>"$LOG"
# config/ is CONFIGURATION the lanes read at run time, not documentation:
# config/generated-paths.conf is the allowlist mc_resolve_generated matches a
# conflicted path against. The library carries the same two entries compiled in
# (MC_GENERATED_PATHS_DEFAULT), so a box without this line degrades to the
# default rather than to nothing — but a change made HERE has to reach the box
# to mean anything, which is what this rsync is for.
[ -d "$CHECKOUT/config" ] && rsync -a --delete "$CHECKOUT/config/" "$HARNESS/config/" 2>>"$LOG"
# fleet.conf (BH-5651): in REGISTRY_SOURCE=db the live file is the registry
# export (bin/registry-export.sh --install also overlays the box maps of the
# catalog/cost-accounts.json the rsync above just copied), never the committed
# copy. rc 1 (file mode, no usable registry, a refused render) copies the
# committed file as before.
"$CHECKOUT/bin/registry-export.sh" --install "$HARNESS" --checkout "$CHECKOUT" 2>>"$LOG" \
  || { [ -f "$CHECKOUT/fleet.conf" ] && { cp "$CHECKOUT/fleet.conf" "$HARNESS/fleet.conf.tmp" && mv "$HARNESS/fleet.conf.tmp" "$HARNESS/fleet.conf"; }; }
# vercel.conf rides along for the same reason fleet.conf does: it is a REGISTRY,
# not a credential — team/project ids and public prod domains, already in git.
# The e2e smoke stage reads it to answer "does this project have previews at
# all?" without burning a wait-preview timeout to find out, and until now it was
# hub-only, so every box would have skipped the stage on a missing file.
# Vercel TOKENS remain hub-only, which is the part that actually matters.
[ -f "$CHECKOUT/vercel.conf" ] && { cp "$CHECKOUT/vercel.conf" "$HARNESS/vercel.conf.tmp" && mv "$HARNESS/vercel.conf.tmp" "$HARNESS/vercel.conf"; }
chmod +x "$HARNESS"/bin/*.sh 2>/dev/null
chmod +x "$HARNESS"/checks/*/check.sh "$HARNESS"/guardrails/*/check.sh 2>/dev/null
# >>> the code copy is live (BH-7122)
# Everything above is the copy: catalog/, agent-core/, bin/, prompts/, fly/,
# checks/, guardrails/, config/, fleet.conf and vercel.conf. `copied` says so
# for this sha, and fleet-propagate reads it after an outer kill: a kill from
# here on is a post-copy timeout, not "OLD harness". Every step below runs
# under hs_step (its own timeout, one step line) or the detached runner
# bin/harness-sync-step.sh. Each deploy step this run will launch gets its
# pending marker now, on the same conditions as its launch below.
HS_SHA=$(git -C "$CHECKOUT" rev-parse HEAD 2>/dev/null)
hs_phase copied
[ -f "$HENV/cloudflare.env" ] && [ -d "$CHECKOUT/worker" ] && hs_pending_queue worker-phase
[ -x "$HARNESS/bin/harness-sync-step.sh" ] && [ -x "$HARNESS/bin/model-prices-deploy-sync.sh" ] && hs_pending_queue model-prices
[ -f "$HENV/cloudflare.env" ] && [ -x "$HARNESS/bin/cost-caps-seed-sync.sh" ] && hs_pending_queue cost-caps
[ -f "$HENV/cloudflare.env" ] && [ -x "$HARNESS/bin/harness-sync-step.sh" ] && [ -x "$HARNESS/bin/console-pages-deploy.sh" ] && hs_pending_queue console-pages
# <<< the code copy is live
# The budget catalog is DB-served too (db-jobs phase 2): push the manifest into
# harness-jobs whenever its tree sha moves — sha-gated like the worker deploys
# below, so a routine deploy is not a PUT per tick. Fail-open: a missed sync
# leaves every lane on the catalog-file fallback chain and retries next deploy;
# it never blocks or delays the deploy itself.
# The manifest's sources are catalog/context-budgets.d/ since BH-6487; the old
# path stays in the pathspec for a checkout from before the split.
hs_catalog_step() {
local CSHA CSTATE CPRC rc=0
CSHA=$(git -C "$CHECKOUT" rev-list -1 HEAD -- catalog/context-budgets.d catalog/context-budgets.json 2>/dev/null)
CSTATE="$HARNESS/state/catalog-synced"
# A STAMP EQUAL TO THE SHA SAYS "PUSHED ONCE", NOT "STILL THERE" (BH-1042, audit
# fact #30: a DB reset with the stamp left behind meant nobody ever re-pushed
# and every lane fell back to the catalog file forever, silently). So ask the
# worker about one lane the manifest declares. rc 2 = it ANSWERED and holds no
# budget_catalog row on that ladder, so the stamp is void and the block below
# pushes again. rc 1 (unreachable, or a manifest with no sizeable lane) keeps
# the stamp: an outage is not a reset, and the next deploy re-asks. One GET per
# DEPLOY run — never per tick, and never a PUT unless the row is really gone.
# `--check` exits above and never reaches this.
if [ -n "$CSHA" ] && [ "$(cat "$CSTATE" 2>/dev/null)" = "$CSHA" ] \
   && [ -f "$CHECKOUT/catalog/context-budgets.json" ]; then
  "$HARNESS/bin/jobs-client.sh" catalog-probe "$CHECKOUT/catalog/context-budgets.json" >/dev/null 2>&1
  CPRC=$?
  if [ "$CPRC" -eq 2 ]; then
    rm -f "$CSTATE"
    echo "$(STAMP) budget catalog stamp voided: harness-jobs holds no budget_catalog row for the manifest's first sized lane (DB reset?) — re-pushing" >> "$LOG"
  fi
fi
if [ -n "$CSHA" ] && [ "$(cat "$CSTATE" 2>/dev/null)" != "$CSHA" ] \
   && [ -f "$CHECKOUT/catalog/context-budgets.json" ]; then
  if "$HARNESS/bin/jobs-client.sh" catalog-sync "$CHECKOUT/catalog/context-budgets.json" >/dev/null 2>&1; then
    echo "$CSHA" > "$CSTATE"
    echo "$(STAMP) budget catalog synced to harness-jobs at ${CSHA:0:7}" >> "$LOG"
  else
    rc=1
  fi
fi
return "$rc"
}
hs_step catalog-sync plain hs_catalog_step
# Machine rules are repo-managed; re-render them from the checkout we just moved.
hs_agent_rules_step() {
  local rc=0
  "$HARNESS/bin/sync-agent-rules.sh" apply >/dev/null 2>&1 || rc=$?
  "$HARNESS/bin/sync-agent-rules.sh" install >/dev/null 2>&1 || rc=$?
  return "$rc"
}
[ -x "$HARNESS/bin/sync-agent-rules.sh" ] && hs_step agent-rules plain hs_agent_rules_step
# Skills are repo-managed too (SDLC item 6): the repeated procedures a session
# loads ON DEMAND live in skills/ and deploy to ~/.claude/skills the same way
# rules do. Additive and non-fatal: a box without the script, or a skills/ that
# fails to copy, keeps every other part of the deploy. The step's rc is the
# main sync-skills run; the orchestrator line below stays exactly as written
# (tests/archie-skill-replays.bh-4064-test.sh R13 runs it alone).
hs_skills_step() {
local rc=0
if [ -x "$HARNESS/bin/sync-skills.sh" ]; then "$HARNESS/bin/sync-skills.sh" >/dev/null 2>&1 || rc=$?; fi
# >>> orchestrator skills (BH-4064)
# Archie's skills (orchestrator/skills/) go to the hub orchestrator's project
# skills, which its turns discover because bin/orchestrate.sh cd's into
# /root/orchestrator. Only where that dir exists (the hub); replays stay here.
[ -x "$HARNESS/bin/sync-skills.sh" ] && [ -d "${ORCHESTRATOR_DIR:-/root/orchestrator}" ] && HARNESS_CHECKOUT="$CHECKOUT" HARNESS_LOG_DIR="$HARNESS/logs" SKILLS_SUBDIR=orchestrator/skills CLAUDE_SKILLS_DIR="${ORCHESTRATOR_DIR:-/root/orchestrator}/.claude/skills" "$HARNESS/bin/sync-skills.sh" >/dev/null 2>&1
# <<< orchestrator skills
return "$rc"
}
hs_step skills plain hs_skills_step
# New code voids pool-halt verdicts — they were issued against the old harness.
# Exception: a halt with a companion .keep file survives deploys — an operator
# judged that spawns must stay down until a named condition is verified
# (2026-08-25 TK-1174/1175: machines booted with empty /root/.claude/CLAUDE.md).
hs_pool_halt_step() {
local _hf _hp _hrc _hb
for _hf in "$HARNESS"/flags/pool-halt-*; do
  [ -e "$_hf" ] || continue
  case "$_hf" in *.keep) continue;; esac
  [ -f "$_hf.keep" ] && continue
  rm -f "$_hf"
  # And the ROW (BH-1373), WHENEVER ONE EXISTS, knob on or off (BH-2010): a row
  # still saying halted=1 puts this file straight back on the next routing sync
  # with the knob on — and with it off, it sits stale until the flip re-halts
  # the project. No row (404) is nothing to clear; an unreadable one is logged.
  # The clear is audited as actor harness-sync.
  _hp=${_hf##*/pool-halt-}
  if [ -x "$HARNESS/bin/jobs-client.sh" ]; then
    _hrc=0; HARNESS="$HARNESS" "$HARNESS/bin/jobs-client.sh" routing-get "$_hp" >/dev/null 2>&1 || _hrc=$?
    case "$_hrc" in
      0)
        _hb=local; flag_file_on builder-fly "$_hp" && { _hb=fly1; flag_file_on fly-pool "$_hp" && _hb=pool; }
        HARNESS="$HARNESS" "$HARNESS/bin/jobs-client.sh" routing-set "$_hp" "$_hb" "$(cat "$HARNESS/flags/fly-pool-app-$_hp" 2>/dev/null)" 0 harness-sync "deploy voids pool-halt (new code)" >/dev/null 2>&1 || echo "$(STAMP) pool-halt-$_hp cleared on disk but the routing row could not be cleared. The next routing sync puts the halt file back until the row is fixed" >> "$LOG"
        ;;
      2) ;;
      *) echo "$(STAMP) pool-halt-$_hp cleared on disk, but whether a routing row still says halted could not be read (rc $_hrc); a stale halted row re-halts it once routing_rows is on" >> "$LOG" ;;
    esac
  fi
done
return 0
}
hs_step pool-halt plain hs_pool_halt_step
# --- Cloudflare workers are REPO-MANAGED too (watchdog stale-deploy, 2026-08-26)
# A worker/ commit without a `wrangler deploy` leaves the LIVE worker on old
# code — the watchdog paged for 38h about a box the repo had already removed
# from its list. Runs only where credentials exist (hub's env/cloudflare.env),
# and only when a worker's tree sha moved past its last successful deploy.
# Failure is an ALERT, not a whisper: a changed-but-undeployed worker is drift.
CFENV="$HENV/cloudflare.env"

# d1_exec <worker-dir> <database> <sql> — one `wrangler d1 execute` round trip.
# Per `--command`, never `--file`: `--file` fails under the hub's OAuth login
# with `Authentication error [code: 10000]` (the operator, 2026-09-19). --yes: from a
# TTY `d1 execute` prompts before touching a remote database, and `timeout 120`
# would turn that prompt into a false failure.
d1_exec() {
  (cd "$1" && set -a && . "$CFENV" && set +a \
     && timeout 120 npx --yes wrangler d1 execute "$2" --remote --yes --command "$3" >>"$LOG" 2>&1)
}

# schema_alert_s — seconds an apply may run before it pages. Env first (the
# fleet-propagate lane's lane_env_apply exports the settings row into it), then
# the same row read directly for the callers that are not that lane
# (update-runners, the pre-build gate), then the code default in
# bin/lib/d1-schema.sh. A non-numeric value falls through, never clamps.
schema_alert_s() {
  local v="${HARNESS_SYNC_SCHEMA_ALERT_S:-}"
  case "$v" in ''|*[!0-9]*) v="" ;; esac
  if [ -z "$v" ] && [ -x "$HARNESS/bin/jobs-client.sh" ]; then
    v=$("$HARNESS/bin/jobs-client.sh" setting-get lane.fleet-propagate.harness_sync_schema_alert_s 2>/dev/null | tr -d '[:space:]')
    case "$v" in ''|*[!0-9]*) v="" ;; esac
  fi
  printf '%s\n' "${v:-$D1_APPLY_ALERT_S_DEFAULT}"
}

# deploy_alert_repeat_s — seconds between two `wrangler deploy FAILED` ALERTS
# for one worker while its deploy keeps failing. Same reader as schema_alert_s:
# env, then the settings row, then the code default. 0 alerts on every failure.
HARNESS_SYNC_DEPLOY_ALERT_REPEAT_S_DEFAULT=3600
deploy_alert_repeat_s() {
  local v="${HARNESS_SYNC_DEPLOY_ALERT_REPEAT_S:-}"
  case "$v" in ''|*[!0-9]*) v="" ;; esac
  if [ -z "$v" ] && [ -x "$HARNESS/bin/jobs-client.sh" ]; then
    v=$("$HARNESS/bin/jobs-client.sh" setting-get lane.fleet-propagate.harness_sync_deploy_alert_repeat_s 2>/dev/null | tr -d '[:space:]')
    case "$v" in ''|*[!0-9]*) v="" ;; esac
  fi
  printf '%s\n' "${v:-$HARNESS_SYNC_DEPLOY_ALERT_REPEAT_S_DEFAULT}"
}

# deploy_fail_note <wname> <wsha> <snap> [<stage> <message>] — one failed
# worker-deploy step. <stage> is `deploy` (the default: `wrangler deploy`,
# BH-6687) or one of the steps before it (BH-6764): `sites-compose`,
# `budgets-compose`, `schema-compose`, `npm-ci`, with <message> the ALERT text.
# The first failure ALERTs; while that step keeps failing it ALERTs again at
# most once per deploy_alert_repeat_s, and a held failure is one
# update-runners.log line. The state is per worker AND per step:
# state/worker-<stage>-failing-<w> is "<first_epoch> <last_alert_epoch>
# <count>"; any other content, or a last alert in the future, counts as
# absent. deploy_fail_clear removes it when the step passes.
# HARNESS_SYNC_NOW pins the clock for tests.
deploy_fail_note() {
  local wname="$1" wsha="$2" snap="$3" stage="${4:-deploy}" msg="${5:-}" f first="" last="" count=0 now rep since
  f="$HARNESS/state/worker-$stage-failing-$wname"
  now="${HARNESS_SYNC_NOW:-$(date +%s)}"
  if read -r first last count _ 2>/dev/null < "$f" \
     && [[ "$first $last $count" =~ ^[0-9]+\ [0-9]+\ [0-9]+$ ]] && [ "$last" -le "$now" ]; then
    count=$((count + 1))
  else
    first="$now"; last=""; count=1
  fi
  since=$(date -u -d "@$first" '+%F %TZ')
  rep=$(deploy_alert_repeat_s)
  if [ -z "$last" ] || [ $((now - last)) -ge "$rep" ]; then
    [ -n "$msg" ] || msg="[$(hostname)] worker/$wname changed (${wsha:0:7}) but wrangler deploy FAILED — LIVE WORKER IS STALE; the next successful update-runners run redeploys it; if it keeps failing the alert medic owns this line (worker snapshot of ${snap:0:7}, see update-runners.log)"
    HARNESS="$HARNESS" "$HARNESS/bin/alert-line.sh" --id "worker-$stage-failed-$wname-$(hostname)" "$msg — failing since $since ($count failed attempt(s)); repeats at most once per ${rep}s while it keeps failing"
    last="$now"
  else
    echo "$(STAMP) worker $wname $stage FAILED again ($count since $since); alert held, next in $((rep - (now - last)))s" >> "$LOG"
  fi
  printf '%s %s %s\n' "$first" "$last" "$count" > "$f.tmp" && mv -f "$f.tmp" "$f"
}

# deploy_fail_clear <wname> <stage> — the step passed: remove its failing state
# and log the recovery, so the next failure alerts at once with a count of 1.
deploy_fail_clear() {
  local f="$HARNESS/state/worker-$2-failing-$1" first count
  [ -e "$f" ] || return 0
  if read -r first _ count _ < "$f" 2>/dev/null && [[ "$first $count" =~ ^[0-9]+\ [0-9]+$ ]]; then
    echo "$(STAMP) worker $1 $2 recovered after $count failed attempt(s) since $(date -u -d "@$first" '+%F %TZ')" >> "$LOG"
  fi
  rm -f "$f"
}

# schema_send <worker-dir> <name> <database> <stmt>... — apply the statements
# in order, SEVERAL PER ROUND TRIP (BH-1538). Chunks are cut by
# d1_chunk_bounds (bytes AND count). A chunk that fails is re-run one statement
# at a time from its first statement — every statement is IF NOT EXISTS / OR
# IGNORE (tests/schema-additive.bh-1000), so re-sending the part of a chunk
# that did land is a no-op — and the first single that fails is the statement
# the ALERTS line names. A failed chunk whose singles ALL pass means the batch
# form itself was refused (multi-statement `--command` under this login), so
# the rest of the apply goes one statement per round trip and says so.
# Returns 1 on a failed statement (ALERTS written); sets SCHEMA_RT.
#
# The slow-apply check runs after EVERY round trip, not per chunk: on the
# per-statement path a 40-statement chunk is ~200 s, and fleet-propagate runs
# this script under `timeout 300`, so a per-chunk check could be killed before
# it ever fired — the silent mid-apply kill BH-1000 fix round 1 describes.
schema_send() {
  local wdir="$1" wname="$2" wdb="$3"; shift 3
  local -a st=("$@") chunks
  local m=$# batch=1 rt=0 alerted=0 limit t0 c f l i head
  limit=$(schema_alert_s); t0=$(date +%s)
  mapfile -t chunks < <(printf '%s\0' "${st[@]}" | d1_chunk_bounds)
  for c in "${chunks[@]}"; do
    read -r f l <<<"$c"
    if [ "$batch" = 0 ] || [ "$f" = "$l" ] \
       || { rt=$((rt+1)); ! d1_exec "$wdir" "$wdb" "$(printf '%s\n' "${st[@]:f:l-f+1}")"; }; then
      [ "$batch" = 1 ] && [ "$f" != "$l" ] \
        && echo "$(STAMP) worker $wname schema apply: round trip for statements $((f+1))-$((l+1))/$m failed — re-running them one statement at a time to name the one that broke" >> "$LOG"
      for ((i=f; i<=l; i++)); do
        rt=$((rt+1))
        d1_exec "$wdir" "$wdb" "${st[$i]}" && { schema_progress $((i+1)); schema_slow $((i+1)); continue; }
        # ONE line, so the head of a multi-line statement is flattened first.
        head=$(printf '%s' "${st[$i]}" | tr '\n\t' '  ' | cut -c1-80)
        HARNESS="$HARNESS" "$HARNESS/bin/alert-line.sh" "[$(hostname)] worker/$wname schema.sql statement $((i+1))/$m failed against D1 $wdb ($head) — deploy of $wname SKIPPED so code never runs ahead of its schema; the next update-runners run retries (update-runners.log)"
        SCHEMA_RT=$rt; return 1
      done
      if [ "$batch" = 1 ] && [ "$f" != "$l" ]; then
        batch=0
        echo "$(STAMP) worker $wname schema apply: batched --command failed where every statement of it passed alone — the rest of this apply goes one statement per round trip" >> "$LOG"
      fi
    fi
    schema_progress $((l+1))
    echo "$(STAMP) worker $wname schema apply: statement $((l+1))/$m on, $rt round trip(s), $(( $(date +%s) - t0 ))s" >> "$LOG"
    schema_slow $((l+1))
  done
  SCHEMA_RT=$rt
  return 0
}

# schema_progress <statements-done-in-this-call> — record how far the apply got,
# so the next pass continues instead of starting over (BH-1555).
#
# WHY. A cold 116-statement apply cannot finish inside the `timeout 300` that
# fleet-propagate gives harness-sync, and the stamp is written LAST on purpose,
# so before this a kill threw the whole apply away: the next pass started at
# statement 1 and was killed in the same place, forever.
#
# WRITTEN ONLY AFTER THE D1 CALL RETURNED 0, never before, and never past a
# failed statement: a kill between the call and this write re-sends one
# idempotent statement on the next pass, which costs a round trip. Writing it
# first would SKIP a statement that never landed, which costs a missing table.
# Atomic (tmp+mv) because the reader is a later run of this same script.
# Reads schema_send's caller's SCHEMA_PROGRESS_* (bash scoping is dynamic).
schema_progress() {
  [ -n "${SCHEMA_PROGRESS_FILE:-}" ] && [ -n "${SCHEMA_PROGRESS_KEY:-}" ] || return 0
  printf '%s %s\n' "$SCHEMA_PROGRESS_KEY" "$(( ${SCHEMA_PROGRESS_BASE:-0} + $1 ))" \
    > "$SCHEMA_PROGRESS_FILE.tmp" 2>/dev/null \
    && mv "$SCHEMA_PROGRESS_FILE.tmp" "$SCHEMA_PROGRESS_FILE" 2>/dev/null
  return 0
}

# schema_slow <statements-done> — one ALERTS line per apply once it has run
# past the threshold. Reads schema_send's locals (bash scoping is dynamic).
schema_slow() {
  local el=$(( $(date +%s) - t0 ))
  [ "$alerted" = 0 ] && [ "$el" -ge "$limit" ] || return 0
  alerted=1
  HARNESS="$HARNESS" "$HARNESS/bin/alert-line.sh" "[$(hostname)] worker/$wname schema apply to D1 $wdb has run ${el}s (threshold ${limit}s, settings row lane.fleet-propagate.harness_sync_schema_alert_s) at statement $1/$m, $rt round trip(s) — lane code is NOT held by it (BH-1538), but this worker deploys only when it ends, and fleet-propagate's timeout 300 kills an apply that outlives it; see update-runners.log"
}

# worker_schema_apply <worker-dir> <name> <database> — put the worker's
# schema.sql on its D1 before the code that reads it deploys. 0 = the schema is
# on (or there was nothing new), deploy; 1 = skip the deploy (ALERTS written).
# <worker-dir> is the pass's snapshot, never the live checkout.
#
# ONCE PER SCHEMA (BH-1000 fix round 1), and since BH-1538 ONLY WHAT CHANGED.
# The stamp is `<schema blob sha> <database>`. With a stamp for THIS database,
# the previous blob is read back out of git and only statements whose text is
# not in it are sent — an edited statement is new text, so it goes too; a
# removed one is simply not re-sent. No stamp, a stamp for another database
# (review round 1, I2: "applied" is only ever true OF A DATABASE), or a previous
# blob git no longer has: the full file, which is always safe because every
# statement is additive and idempotent (tests/schema-additive.bh-1000). A D1
# RESET under the same name is the one thing a stamp cannot see; that is the
# hand step in worker/jobs/README.md: `rm state/worker-schema-applied-<worker>
# state/worker-schema-progress-<worker>` — BOTH, because the progress file's key
# (blob, database, baseline) survives a reset too, and a leftover one would skip
# statements the reset database no longer has (BH-1555 lead review).
worker_schema_apply() {
  local wdir="$1" wname="$2" wdb="$3" key state prev psha mode="full apply" s WSCSHA
  local pfile pkey pdone pline edited="" obj i
  local -a all pend
  local -A seen prevobj
  # -w (BH-6005): the composed schema.sql is in no commit once the file leaves
  # git, so write its blob into the checkout's object store. The next run's
  # `cat-file blob "$psha"` delta then finds it. An unreachable loose blob is
  # pruned by `git gc` after gc.pruneExpire (2 weeks by default); after that the
  # next change falls back to the full apply, which is idempotent.
  WSCSHA=$(git -C "$CHECKOUT" hash-object -w "$wdir/schema.sql" 2>/dev/null)
  key="$WSCSHA $wdb"; state="$HARNESS/state/worker-schema-applied-$wname"
  pfile="$HARNESS/state/worker-schema-progress-$wname"
  prev=$(cat "$state" 2>/dev/null)
  if [ -n "$WSCSHA" ] && [ "$prev" = "$key" ]; then
    rm -f "$pfile" 2>/dev/null
    echo "$(STAMP) worker $wname schema.sql unchanged (${WSCSHA:0:7}) — apply skipped, deploying" >> "$LOG"
    return 0
  fi
  mapfile -t -d '' all < <(d1_schema_statements "$wdir/schema.sql")
  # A present schema.sql that reads as ZERO statements is a broken read
  # (unreadable file, a splitter that is not there), not an empty schema:
  # deploying on it is the 2026-09-19 incident again, with a tidier log.
  if [ "${#all[@]}" = 0 ]; then
    HARNESS="$HARNESS" "$HARNESS/bin/alert-line.sh" "[$(hostname)] worker/$wname has a schema.sql but it read as 0 statements against D1 $wdb — deploy of $wname SKIPPED so code never runs ahead of its schema; the next update-runners run retries (update-runners.log)"
    return 1
  fi
  psha=${prev%% *}
  pend=("${all[@]}")
  if [ -n "$prev" ] && [ "${prev#* }" = "$wdb" ] && git -C "$CHECKOUT" cat-file -e "$psha" 2>/dev/null; then
    while IFS= read -r -d '' s; do
      seen["$s"]=1
      obj=$(d1_stmt_object "$s")
      [ -n "$obj" ] && prevobj["$obj"]=1
    done \
      < <(d1_schema_statements <(git -C "$CHECKOUT" cat-file blob "$psha" 2>/dev/null))
    pend=()
    for i in "${!all[@]}"; do
      [ -n "${seen["${all[$i]}"]:-}" ] && continue
      pend+=("${all[$i]}")
      # BH-1555: a CHANGED statement that defines an object the previous blob
      # already defined is an EDIT to a live object, and `CREATE ... IF NOT
      # EXISTS` is a silent no-op on D1 in that case — it is sent, it succeeds
      # and it changes nothing. The schema is additive by contract, so this
      # cannot be fixed by sending it differently and the apply does NOT fail
      # on it; what it must not do is pass unnoticed. The ordinal named is the
      # statement's position in the WHOLE file, which is what someone opening
      # schema.sql can count to — its index in the pending list means nothing
      # to a reader.
      obj=$(d1_stmt_object "${all[$i]}")
      [ -n "$obj" ] && [ -n "${prevobj["$obj"]:-}" ] \
        && edited="${edited:+$edited, }statement $((i+1)): $obj"
    done
    mode="delta vs ${psha:0:7}"
    if [ -n "$edited" ]; then
      HARNESS="$HARNESS" "$HARNESS/bin/alert-line.sh" "[$(hostname)] worker/$wname schema.sql edits the definition of an EXISTING object on D1 $wdb ($edited) — CREATE ... IF NOT EXISTS is a silent no-op there; a real change needs a new object or an explicit migration (BH-1555)"
      echo "$(STAMP) worker $wname schema.sql redefines an object D1 already has ($edited) — applying anyway, the change will NOT take effect (BH-1555)" >> "$LOG"
    fi
  fi
  # BH-1555, resume. The progress file is only ever trusted when its key names
  # the SAME pending list it was counted against — the target blob, the
  # database, and the baseline the delta was computed from. Anything else
  # (schema edited again since, another database, another baseline, a count out
  # of range, unparseable) is discarded rather than clamped: a wrong skip is a
  # statement that never lands, which is the BH-1000 outage.
  SCHEMA_PROGRESS_FILE="$pfile"
  SCHEMA_PROGRESS_KEY="$WSCSHA $wdb ${psha:-none}"
  SCHEMA_PROGRESS_BASE=0
  if [ -f "$pfile" ]; then
    pline=$(cat "$pfile" 2>/dev/null)
    pkey="${pline% *}"; pdone="${pline##* }"
    case "$pdone" in ''|*[!0-9]*) pdone=0 ;; esac
    if [ "$pkey" = "$SCHEMA_PROGRESS_KEY" ] && [ "$pdone" -gt 0 ] && [ "$pdone" -lt "${#pend[@]}" ]; then
      echo "$(STAMP) worker $wname schema apply: resuming at statement $((pdone+1))/${#pend[@]} (progress from a run that did not finish)" >> "$LOG"
      pend=("${pend[@]:pdone}")
      SCHEMA_PROGRESS_BASE=$pdone
    else
      rm -f "$pfile" 2>/dev/null
    fi
  fi
  SCHEMA_RT=0
  if [ "${#pend[@]}" -gt 0 ]; then
    schema_send "$wdir" "$wname" "$wdb" "${pend[@]}" || return 1
  fi
  echo "$(STAMP) worker $wname schema.sql applied ($((SCHEMA_PROGRESS_BASE + ${#pend[@]})) statements; $SCHEMA_RT round trip(s); $mode) to $wdb" >> "$LOG"
  # Write-then-tell: the stamp lands only after every statement went through,
  # so a killed or failed apply always re-applies — and the progress file goes
  # first, so the two can never both claim to be the truth.
  rm -f "$pfile" 2>/dev/null
  [ -n "$WSCSHA" ] && printf '%s\n' "$key" > "$state"
  return 0
}

# snapshot_tree <sha> — materialise worker/, catalog/, agent-core/, the lane
# composer, the schema composer and the llm-sites composer of commit <sha> into
# a fresh directory under state/ and print its path. agent-core/ is there
# because worker/jobs's staff routes import ../../../../agent-core/ (BH-5559),
# and without it the bundle cannot resolve them (BH-6687).
# What a worker deploy bundles must be ONE commit (#1548 review C1): the worker phase runs outside the deploy lock, so a concurrent
# harness-sync can `git pull` the checkout while `wrangler deploy` bundles, and
# a pull that brings code AND the schema.sql statement it reads would put that
# code live before the statement is applied. `git archive` reads objects by sha, which a pull never changes.
snapshot_tree() {
  local d p paths=()
  # Only the paths this commit has: `git archive` refuses the whole call on a
  # pathspec that matches nothing (a repo with no catalog/, no composer).
  for p in worker catalog agent-core bin/lanes-build.sh bin/schema-build.sh bin/llm-sites-build.sh bin/context-budgets-build.sh bin/lib; do
    git -C "$CHECKOUT" cat-file -e "$1:$p" 2>/dev/null && paths+=("$p")
  done
  d=$(mktemp -d "$HARNESS/state/worker-snap.XXXXXX" 2>/dev/null) || return 1
  if git -C "$CHECKOUT" archive "$1" "${paths[@]}" 2>>"$LOG" \
       | tar -x -C "$d" 2>>"$LOG" && [ -d "$d/worker" ]; then
    printf '%s\n' "$d"; return 0
  fi
  snapshot_drop "$d"; return 1
}

# snapshot_drop <dir> — remove a snapshot, and only ever a snapshot.
snapshot_drop() {
  case "$1" in "$HARNESS/state/worker-snap."?*) rm -rf "$1" ;; esac
}

# deploy_workers — one pass over the workers of ONE commit: apply each changed
# worker's schema, then deploy it, both from an immutable snapshot of that
# commit, and stamp that commit's key. A pull that lands mid-pass changes
# nothing this pass reads; the next pass sees the new key and applies before it
# deploys.
deploy_workers() {
  local SNAP ROOT="" WNAME WDIR WSHA WLANES WLSHA WCSHA WSITES WSSHA WSTATE WDB
  SNAP=$(git -C "$CHECKOUT" rev-parse HEAD 2>/dev/null) || return 0
  # Only the worker-lock holder is here, so any snapshot left behind is from a
  # killed pass and nobody is reading it.
  local old
  for old in "$HARNESS"/state/worker-snap.*; do [ -e "$old" ] && snapshot_drop "$old"; done
  for WNAME in $(git -C "$CHECKOUT" ls-tree -d --name-only "$SNAP" worker/ 2>/dev/null | sed 's|^worker/||'); do
    git -C "$CHECKOUT" cat-file -e "$SNAP:worker/$WNAME/wrangler.jsonc" 2>/dev/null \
      || git -C "$CHECKOUT" cat-file -e "$SNAP:worker/$WNAME/wrangler.toml" 2>/dev/null || continue
    WSHA=$(git -C "$CHECKOUT" rev-list -1 "$SNAP" -- "worker/$WNAME" 2>/dev/null)
    [ -n "$WSHA" ] || continue
    WLANES=0
    # >>> lane registry bundled into the worker (BH-1247)
    # worker/jobs BUNDLES catalog/lanes.json with a static ESM import, and that
    # file is GENERATED from catalog/lanes.d/ and no longer committed. Two
    # consequences, and both are handled here rather than at the deploy line:
    #
    #   1. IT MUST EXIST BEFORE `wrangler deploy` RUNS, or the bundle fails on a
    #      module it cannot resolve. It is rendered into the snapshot AFTER the
    #      change-key skip below and before the schema apply and the deploy —
    #      only a tick that is actually going to deploy this worker composes
    #      anything (BH-1304).
    #   2. ITS SOURCES MUST BE PART OF THIS WORKER'S CHANGE KEY. `git rev-list
    #      -1 HEAD -- worker/<name>` does not move when a lane file changes, so
    #      the LIVE worker kept serving the registry it was bundled with —
    #      /api/lanes/registry and the settings page showing a lane list older
    #      than the fleet's. That was already true while catalog/lanes.json was
    #      committed (it has never lived under worker/), so this is a
    #      pre-existing staleness fixed in passing, not one introduced here.
    #      Only a worker that actually imports the registry takes the extra key:
    #      the others must not redeploy every time somebody adds a lane.
    if git -C "$CHECKOUT" grep -q 'catalog/lanes\.json' "$SNAP" -- "worker/$WNAME" 2>/dev/null; then
      # bin/lanes-build.sh is in the pathspec with the lane files (BH-1247
      # review, I2): a change to the COMPOSITION changes the bundle with every
      # lane file untouched, and without it the live worker would keep serving
      # the registry it was built with.
      WLSHA=$(git -C "$CHECKOUT" rev-list -1 "$SNAP" -- catalog/lanes.d bin/lanes-build.sh 2>/dev/null)
      [ -n "$WLSHA" ] && WSHA="$WSHA-lanes-$WLSHA"
      WLANES=1
    fi
    # <<< lane registry bundled into the worker
    # >>> agent-core bundled into the worker (BH-6687)
    # A worker that imports agent-core/ bundles it, so an agent-core/-only
    # commit must move this worker's key, or the live worker keeps the old code.
    if git -C "$CHECKOUT" grep -q 'agent-core/' "$SNAP" -- "worker/$WNAME" 2>/dev/null; then
      WCSHA=$(git -C "$CHECKOUT" rev-list -1 "$SNAP" -- agent-core 2>/dev/null)
      [ -n "$WCSHA" ] && WSHA="$WSHA-core-$WCSHA"
    fi
    # <<< agent-core bundled into the worker
    # >>> llm-sites catalog bundled into the worker (BH-4987)
    # worker/jobs also imports catalog/llm-sites.json statically, and that file
    # is composed from catalog/llm-sites.d/ and no longer committed. Same two
    # rules as the lane registry: its sources join the change key, and it is
    # composed in the snapshot before the deploy below.
    WSITES=0
    if git -C "$CHECKOUT" grep -q 'catalog/llm-sites\.json' "$SNAP" -- "worker/$WNAME" 2>/dev/null \
       && git -C "$CHECKOUT" cat-file -e "$SNAP:catalog/llm-sites.d" 2>/dev/null; then
      WSSHA=$(git -C "$CHECKOUT" rev-list -1 "$SNAP" -- catalog/llm-sites.d bin/llm-sites-build.sh 2>/dev/null)
      [ -n "$WSSHA" ] && WSHA="$WSHA-sites-$WSSHA"
      WSITES=1
    fi
    # <<< llm-sites catalog bundled into the worker
    # >>> budget manifest bundled into the worker (BH-6487)
    # worker/jobs/src/routes/llm-sites.js imports catalog/context-budgets.json,
    # composed from catalog/context-budgets.d/ since BH-6487. Same two rules.
    WBUDGETS=0
    if git -C "$CHECKOUT" grep -q 'catalog/context-budgets\.json' "$SNAP" -- "worker/$WNAME" 2>/dev/null \
       && git -C "$CHECKOUT" cat-file -e "$SNAP:catalog/context-budgets.d" 2>/dev/null; then
      WBSHA=$(git -C "$CHECKOUT" rev-list -1 "$SNAP" -- catalog/context-budgets.d bin/context-budgets-build.sh 2>/dev/null)
      [ -n "$WBSHA" ] && WSHA="$WSHA-budgets-$WBSHA"
      WBUDGETS=1
    fi
    # <<< budget manifest bundled into the worker
    WSTATE="$HARNESS/state/worker-deployed-$WNAME"
    [ "$(cat "$WSTATE" 2>/dev/null)" = "$WSHA" ] && continue
    if [ -z "$ROOT" ] && ! ROOT=$(snapshot_tree "$SNAP"); then
      HARNESS="$HARNESS" "$HARNESS/bin/alert-line.sh" "[$(hostname)] worker deploys at ${SNAP:0:7} could not snapshot the checkout (git archive into $HARNESS/state) — LIVE WORKERS ARE STALE; the next harness-sync run retries (update-runners.log)"
      return 0
    fi
    WDIR="$ROOT/worker/$WNAME"
    # >>> lane registry render (BH-1304: inside the CHANGED branch)
    # Composed only when this worker is about to deploy. Its sources are in the
    # change key above, so an unchanged key means the bundle would be identical
    # and a no-op tick composes nothing — which on the hub is every tick but a
    # few, once every five minutes, forever. Compose failure stays an ALERT and
    # the deploy still runs: wrangler is what discovers it cannot resolve the
    # module, and it writes its own line when it fails.
    if [ "$WLANES" = 1 ] && [ -x "$ROOT/bin/lanes-build.sh" ]; then
      "$ROOT/bin/lanes-build.sh" --root "$ROOT" --write >/dev/null 2>&1 \
        || HARNESS="$HARNESS" "$HARNESS/bin/alert-line.sh" "[$(hostname)] worker/$WNAME imports catalog/lanes.json and it could NOT be composed from catalog/lanes.d — the deploy below will fail to bundle; fix the lane files"
    fi
    # <<< lane registry render
    # >>> llm-sites catalog compose (BH-4987)
    # Unlike the lane render above, a failure here stops THIS worker: no apply,
    # no deploy, no stamp, one ALERT. The fragments are the source, so a bad
    # one is a refused compose, and a deploy that bundled an older catalog
    # would stamp a key it does not serve.
    if [ "$WSITES" = 1 ]; then
      if ! "$ROOT/bin/llm-sites-build.sh" --compose --repo "$ROOT" >>"$LOG" 2>&1; then
        deploy_fail_note "$WNAME" "$WSHA" "$SNAP" sites-compose "[$(hostname)] worker/$WNAME catalog/llm-sites.json could NOT be composed from catalog/llm-sites.d at ${SNAP:0:7} — deploy of $WNAME SKIPPED; fix the fragment bin/llm-sites-build.sh --check names (update-runners.log)"
        continue
      fi
      deploy_fail_clear "$WNAME" sites-compose
    fi
    # <<< llm-sites catalog compose
    # >>> budget manifest compose (BH-6487) — the llm-sites rule: a refused
    # compose stops THIS worker, no apply, no deploy, no stamp, one ALERT.
    if [ "$WBUDGETS" = 1 ]; then
      if ! "$ROOT/bin/context-budgets-build.sh" --compose --repo "$ROOT" >>"$LOG" 2>&1; then
        deploy_fail_note "$WNAME" "$WSHA" "$SNAP" budgets-compose "[$(hostname)] worker/$WNAME catalog/context-budgets.json could NOT be composed from catalog/context-budgets.d at ${SNAP:0:7} — deploy of $WNAME SKIPPED; fix the fragment bin/context-budgets-build.sh --check names (update-runners.log)"
        continue
      fi
      deploy_fail_clear "$WNAME" budgets-compose
    fi
    # <<< budget manifest compose
    # >>> schema compose (BH-6005)
    # worker/<w>/schema.sql is composed from worker/<w>/schema.d/ (BH-4987), and
    # the file is leaving git (BH-6005). So the snapshot's schema.sql is composed
    # here, from this snapshot's own fragments and composer, before the apply and
    # the deploy read it. While the file is still tracked the bytes are the same
    # (CI's schema-build.sh --check), so the stamp says unchanged. A compose that
    # fails stops THIS worker: no apply, no deploy, no stamp, one ALERT.
    if [ -d "$WDIR/schema.d" ]; then
      if ! "$ROOT/bin/schema-build.sh" --root "$ROOT" --worker "$WNAME" --to "$WDIR/schema.sql" >>"$LOG" 2>&1; then
        deploy_fail_note "$WNAME" "$WSHA" "$SNAP" schema-compose "[$(hostname)] worker/$WNAME schema.sql could NOT be composed from schema.d at ${SNAP:0:7} — deploy of $WNAME SKIPPED so code never runs ahead of its schema; the next update-runners run retries (update-runners.log)"
        continue
      fi
      deploy_fail_clear "$WNAME" schema-compose
    fi
    # <<< schema compose
    # >>> d1 schema apply
    # A worker's TABLES ship with the deploy that reads them (BH-1000). On
    # 2026-09-19 worker/jobs's hub_lease table existed only in schema.sql,
    # applying it was a hand step nobody did, #785's code deployed on top of a
    # missing table and 52 gated hub lanes stopped for half an hour on an
    # uncaught 1101. So the schema goes on before the code does; no deploy and
    # NO STAMP on a failed apply — the retry is the whole point. Both read the
    # SAME snapshot, so the code deployed is the code this schema was written for.
    WDB=""
    command -v d1_database_name >/dev/null 2>&1 && WDB=$(d1_database_name "$WDIR")
    if [ -f "$WDIR/schema.sql" ] && [ -n "$WDB" ]; then
      worker_schema_apply "$WDIR" "$WNAME" "$WDB" || continue
    fi
    # <<< d1 schema apply
    # >>> worker npm ci (BH-5618)
    # The snapshot is a git archive, so it has no node_modules, and a worker
    # with a lockfile imports a package wrangler must bundle
    # (worker/jobs: @sentry/cloudflare). Without this the bundle fails on an
    # unresolved import. --omit=dev keeps test-only packages out. Same contract
    # as the schema apply: no deploy and NO STAMP on a failed install.
    if [ -f "$WDIR/package-lock.json" ]; then
      if ! (cd "$WDIR" && timeout 300 npm ci --omit=dev --no-audit --no-fund >>"$LOG" 2>&1); then
        deploy_fail_note "$WNAME" "$WSHA" "$SNAP" npm-ci "[$(hostname)] worker/$WNAME npm ci FAILED (${WSHA:0:7}) — deploy of $WNAME SKIPPED, LIVE WORKER IS STALE; the next update-runners run retries (update-runners.log)"
        continue
      fi
      deploy_fail_clear "$WNAME" npm-ci
    fi
    # <<< worker npm ci
    # BH-6813: a worker whose src reads HARNESS_SHA (the Sentry harness_sha tag)
    # gets the snapshot sha as a var, so each event names the build it ran.
    local WVAR=()
    grep -rqs HARNESS_SHA "$WDIR/src" && WVAR=(--var "HARNESS_SHA:$SNAP")
    if (cd "$WDIR" && set -a && . "$CFENV" && set +a \
        && timeout 300 npx --yes wrangler deploy "${WVAR[@]}" >>"$LOG" 2>&1); then
      echo "$WSHA" > "$WSTATE"
      echo "$(STAMP) worker $WNAME deployed at ${WSHA:0:7} (snapshot of ${SNAP:0:7})" >> "$LOG"
      deploy_fail_clear "$WNAME" deploy
    else
      deploy_fail_note "$WNAME" "$WSHA" "$SNAP"
    fi
  done
  [ -n "$ROOT" ] && snapshot_drop "$ROOT"
  return 0
}

# >>> worker phase, outside the deploy lock (BH-1538)
# bin/ prompts/ catalog/ and the rest are already live above. Until BH-1538 the
# worker loop ran under locks/harness-sync.lock, so a long D1 apply held it:
# every other harness-sync exited 20 on the busy lock and fleet-propagate
# DEFERRED, and on 2026-09-22 the hub ran lane code 12 commits behind main for
# 30+ minutes. So the deploy lock is released HERE and the worker phase takes
# its own lock. A run that finds it busy leaves the PENDING marker and moves on
# with its bin/ already deployed; the holder re-checks the marker AFTER it
# releases, so the hand-off cannot drop a run:
#   - the busy run touches the marker BEFORE it tries the lock;
#   - the holder releases, THEN tests the marker, and takes the lock again with
#     -n if it is there. If that -n fails, the other run holds it and will see
#     its own marker.
# Outside the deploy lock the CHECKOUT can move under a pass, so no pass reads
# it for what it deploys: deploy_workers pins one commit and applies + deploys
# from a `git archive` snapshot of it (snapshot_tree, #1548 review C1).
flock -u 8 2>/dev/null; exec 8>&-
WPENDING="$HARNESS/state/harness-sync-workers-pending"
# hs_worker_phase — the worker phase as one post-copy deploy step (BH-7122):
# hs_step runs it under the post-step timeout, and a cut or failed phase keeps
# state/harness-sync-pending/worker-phase. The body is unchanged.
hs_worker_phase() {
  # The schema splitter, sourced HERE and not at the top of the file: the rsync
  # above has already put this checkout's bin/lib into $HARNESS, so the run that
  # FIRST brings this library onto a box also applies with it, instead of
  # deploying the new worker once with no schema and picking the library up a
  # day later. Optional: a box without the library deploys exactly as it did
  # before BH-1000 rather than dying on an undefined function.
  . "${HARNESS:-/root/harness}/bin/lib/d1-schema.sh" 2>/dev/null \
    || . "$(dirname "${BASH_SOURCE[0]}")/lib/d1-schema.sh" 2>/dev/null || true
  : > "$WPENDING"
  exec 7>"$HARNESS/locks/harness-sync-workers.lock"
  while [ -e "$WPENDING" ] && flock -n 7; do
    rm -f "$WPENDING"
    deploy_workers
    flock -u 7
  done
  exec 7>&-
  [ -e "$WPENDING" ] \
    && echo "$(STAMP) harness sync: worker phase busy in another harness-sync (a D1 schema apply) — bin/ prompts/ catalog/ are live, the workers of this run are left to it via state/harness-sync-workers-pending" >> "$LOG"
  # A worker step that is still failing has its state/worker-<stage>-failing-<w>
  # (deploy_fail_note). Then the phase is not done, and its marker stays.
  local _wf
  for _wf in "$HARNESS"/state/worker-*-failing-*; do [ -e "$_wf" ] && return 1; done
  return 0
}
if [ -f "$CFENV" ] && [ -d "$CHECKOUT/worker" ]; then
  hs_step worker-phase deploy hs_worker_phase
fi
# <<< worker phase
# Last, after every rsync: "stamped success without deploying" must be
# impossible, so the write-then-tell ordering is the whole deploy, then the
# stamp.
stamp_state harness-sync-last-success
# >>> model prices on deploy (BH-1566)
# A commit that prices a new model puts it in the model_prices table (hub) and
# in this box's state/model-prices.json in the SAME deploy, instead of at the
# next 04:30Z refresh. Keyed on the commit that last touched a price input, so
# a deploy that touches none costs one `git rev-list`. After the stamp and
# outside the deploy lock: it can never veto or fail a deploy.
# DETACHED (BH-1890): on the hub the first deploy of a price change can take
# about 200 s (the refresh alone is up to 150 s), and fleet-propagate runs this
# whole script under `timeout 300`, so a foreground hook got the sync killed
# after its stamp and a false `hub=fail(rc=124)`. So it runs in its own session
# (setsid, out of the process group that timeout kills), capped at 600 s,
# writing to its own logs/model-prices-deploy-sync.log; stdout stays one status
# line. Its own `flock -n` on locks/model-prices-deploy-sync.lock dedupes the
# next deploy's launch while this one runs. The child closes 6-9 so it holds
# no lock it inherited: this script's own 7 and 8 are closed above, but the
# CALLER's are not, and fleet-propagate runs this under its flock on fd 9 —
# an inherited fd 9 would keep that lock held for the hook's whole lifetime
# and every fleet-propagate run meanwhile would `exit 0` silently.
# BH-7122: bin/harness-sync-step.sh, when it is there, goes in front of the
# timeout: it writes the step line, keeps the pending marker on a failure and
# does not launch while the hook's own lock is held (rc=busy).
if [ -x "$HARNESS/bin/model-prices-deploy-sync.sh" ]; then
  _mp_pre=; command -v setsid >/dev/null 2>&1 && _mp_pre=setsid
  _mp_run=(); [ -x "$HARNESS/bin/harness-sync-step.sh" ] && _mp_run=("$HARNESS/bin/harness-sync-step.sh" --step model-prices --kind deploy --lock "$HARNESS/locks/model-prices-deploy-sync.lock" --sha "${HS_SHA:-}" --)
  ( HARNESS="$HARNESS" HARNESS_CHECKOUT="$CHECKOUT" $_mp_pre ${_mp_run[@]+"${_mp_run[@]}"} timeout 600 \
      "$HARNESS/bin/model-prices-deploy-sync.sh" </dev/null \
      >>"$HARNESS/logs/model-prices-deploy-sync.log" 2>&1 9>&- 8>&- 7>&- 6>&- & ) || true
fi
# <<< model prices on deploy
# >>> doc indexes, detached (BH-6806)
# docs/verification-map/README.md and docs/LLM_CALL_SITES.md are generated and
# git-ignored, so each box rebuilds them; bin/verification-map.sh renders the
# project primers from the README. That build ran in the foreground before the
# rsyncs until BH-6806: on the hub under load it ran 20+ minutes, fleet-propagate's
# `timeout 300` killed every sync (rc 124) for about 6 hours on 2026-10-14, and
# merged code and the worker were not live. Nothing in a sync or a worker
# deploy reads either file, so the build runs HERE, after the rsyncs, the worker
# phase and the stamp, in its own session (setsid, out of the process group
# that timeout kills), bounded by DOCS_SYNC_TIMEOUT_S, 6-9 closed like the
# model-prices hook above. bin/docs-sync.sh takes its own `flock -n`, skips a
# build whose inputs are unchanged, and writes one duration line per build to
# update-runners.log; a failed or killed build stamps nothing and is retried by
# the next sync.
if [ -x "$HARNESS/bin/docs-sync.sh" ]; then
  _ds_pre=; command -v setsid >/dev/null 2>&1 && _ds_pre=setsid
  _ds_to="${DOCS_SYNC_TIMEOUT_S:-1800}"; case "$_ds_to" in ''|0|*[!0-9]*) _ds_to=1800 ;; esac
  _ds_run=(); [ -x "$HARNESS/bin/harness-sync-step.sh" ] && _ds_run=("$HARNESS/bin/harness-sync-step.sh" --step docs-sync --kind plain --lock "$HARNESS/locks/docs-sync.lock" --sha "${HS_SHA:-}" --)
  ( HARNESS="$HARNESS" HARNESS_CHECKOUT="$CHECKOUT" $_ds_pre ${_ds_run[@]+"${_ds_run[@]}"} timeout -k 30 "$_ds_to" \
      "$HARNESS/bin/docs-sync.sh" </dev/null \
      >>"$HARNESS/logs/docs-sync.log" 2>&1 9>&- 8>&- 7>&- 6>&- & ) || true
fi
# <<< doc indexes
# >>> cost caps seed on deploy (BH-4155)
# A registry-seed cap row binds above catalog/{cost,lane}-caps.conf, and
# schema.sql's INSERT OR IGNORE never moves one, so a reviewed catalog edit
# reaches the running caps only through this re-seed. Only where cloudflare.env
# is (the hub: one POST for the fleet, not one per box). Keyed on the two files'
# bytes, so a sync that touched neither sends nothing; after the stamp, capped
# at 60 s, never vetoes a deploy. Failure is one ALERTS line per catalog content.
if [ -f "$CFENV" ] && [ -x "$HARNESS/bin/cost-caps-seed-sync.sh" ]; then
  hs_cost_caps_step() { HARNESS="$HARNESS" "$HARNESS/bin/cost-caps-seed-sync.sh" </dev/null >/dev/null 2>&1 9>&- 8>&- 7>&- 6>&-; }
  hs_step cost-caps deploy hs_cost_caps_step || true
fi
# <<< cost caps seed on deploy
# >>> console pages deploy (BH-3554)
# console-ui/ reached the live console only by hand: it sat 15 days on dee684a1
# (2026-09-29). Same shape as the model-prices hook above and for the same
# reason: npm ci + the suite + vite + the upload run minutes, fleet-propagate
# runs this script under `timeout 300`, so it runs DETACHED in its own session,
# its own log, 6-9 closed (never holds fleet-propagate's fd-9 flock). The script
# gates itself (the knob, the settings-row sha, its own flock -n), so a no-op
# run costs one git rev-list and one settings GET. Only where cloudflare.env is.
if [ -f "$CFENV" ] && [ -x "$HARNESS/bin/console-pages-deploy.sh" ]; then
  _cp_pre=; command -v setsid >/dev/null 2>&1 && _cp_pre=setsid
  _cp_to="${CONSOLE_PAGES_DEPLOY_TIMEOUT_S:-1500}"; case "$_cp_to" in ''|*[!0-9]*) _cp_to=1500 ;; esac
  _cp_run=(); [ -x "$HARNESS/bin/harness-sync-step.sh" ] && _cp_run=("$HARNESS/bin/harness-sync-step.sh" --step console-pages --kind deploy --lock "$HARNESS/locks/console-pages-deploy.lock" --sha "${HS_SHA:-}" --)
  ( HARNESS="$HARNESS" HARNESS_CHECKOUT="$CHECKOUT" HARNESS_ENV_DIR="$HENV" $_cp_pre ${_cp_run[@]+"${_cp_run[@]}"} timeout -k 30 "$_cp_to" \
      "$HARNESS/bin/console-pages-deploy.sh" </dev/null \
      >>"$HARNESS/logs/console-pages-deploy.log" 2>&1 9>&- 8>&- 7>&- 6>&- & ) || true
fi
# <<< console pages deploy
# >>> harness checkout code graph (BH-113)
# After the stamp and outside the deploy lock, so a slow or broken index can
# never delay, veto or fail a deploy. Silent: stdout stays one status line. The
# availability note lands in state/codegraph-harness-checkout.
hs_codegraph_step() { HARNESS="$HARNESS" HARNESS_CHECKOUT="$CHECKOUT" "$HARNESS/bin/codegraph-harness-index.sh" >/dev/null 2>&1; }
[ -x "$HARNESS/bin/codegraph-harness-index.sh" ] \
  && hs_step codegraph plain hs_codegraph_step || true
# <<< harness checkout code graph
hs_phase done
if [ "$BEFORE" = "$AFTER" ]; then
  echo "deployed $AFTER (checkout already current, live files reconciled)"
else
  echo "$(STAMP) harness synced: $BEFORE -> $AFTER (origin/$BRANCH)" >> "$LOG"
  echo "synced $BEFORE -> $AFTER"
fi
exit 0
