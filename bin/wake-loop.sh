#!/bin/bash
# bin/wake-loop.sh — EVENTS, NOT CLOCKS. Reads the `wakes` doorbell table and
# runs the lane that owns each press immediately, instead of waiting for that
# lane's cron. Design and ops: docs/EVENTS.md.
#
# THE WAIT THIS REMOVES (the operator, 2026-09-12). Every post-review stage advanced
# only on a tick: the merge conductor */5, the merge sweep every 10, the deploy
# train */15 plus a 20-minute self-source floor, post-merge QA every 30-60, and
# the triage gate's 45-minute queue brake on top of all of it. Worst case a
# ticket spent 150-240 minutes doing nothing but waiting for clocks, with
# nothing wrong anywhere. No webhook receiver existed in bin/, worker/ or
# console-ui/functions, so the only way the fleet learned GitHub had changed was
# to go and look on a schedule.
#
# THE CRON LINES STAY, AND THAT IS THE SAFETY ARGUMENT. This loop is a
# SHORTCUT, never a dependency. With the GitHub webhook uninstalled, the
# worker's GITHUB_WEBHOOK_SECRET unset, harness-jobs unreachable or this script
# not installed at all, no wake is ever read and every lane fires on its own
# clock exactly as it does today. Nothing anywhere waits for a wake.
#
# WHAT IT RUNS, per wake kind — always the lane's OWN script, never a
# reimplementation of what that script does:
#   pr, checks   bin/merge-conductor.sh   (fleet-wide; it has its own flock)
#   push         bin/deploy-train.sh <project>, plus this project's own triage
#                tick when bin/unblocked-children.sh says the merge released a
#                Blocked-by child OR the coalescing window is holding keys for
#                this project (BH-1130: this arm takes the cooldown and spends
#                the un-brake those keys were waiting on, so it carries them) —
#                tried through bin/launch-fastpath.sh on the owning box first,
#                and the tick is bought only when that did not launch every key
#   deploy       bin/postmerge-qa.sh <project>
#   deploy_failed, merge_group   nothing yet (BH-4058): recorded and acked
#                quietly, and the wake-class row hooks still see them
#   queue        bin/fly-dispatch.sh + bin/fly-pool-tick.sh (hub, class
#                wake-lanes-queue; bin/lib/wake-class-queue.sh)
#   issue        touch state/wake-<project>, which bin/triage-gate.sh consumes
#                ONE-SHOT before its 45-minute queue brake, AND this project's
#                own bin/run-triage.sh on the box fleet.conf says owns it —
#                again through bin/launch-fastpath.sh on that box first, with
#                the tick bought only when it did not launch every key
#   lead-review  bin/lead-review.sh tick (build boxes; the owning box's claim)
#   lead-land    bin/lead-review-land.sh (hub only; every repo)
#                Both rung by bin/lib/lead-chain-wake.sh (BH-4057), one launch
#                per drain, no cooldown; flags/lead-chain-wake-off stops both
#
# A CLOSURE IS ABOUT THE TICKETS IT RELEASED (the operator, 2026-09-15). Every wake names
# the object that MOVED, and for a close or a merge that object is the one with
# nothing left to do: what the tick can act on is the tickets whose bodies say
# `Blocked-by: #<it>`. So an issue wake whose object is now CLOSED, and a push
# whose merge closed something, expand their scope through
# bin/unblocked-children.sh (which has answered exactly that question since
# TK-332) and carry the released tickets' keys as well as their own — plus the
# closure itself, in state/wake-closed-<project>, because the ai-build-scoped
# fingerprint on the far box cannot carry the closure of a de-labelled parent.
# The same expansion first closes any decompose parent whose children have all
# merged (bin/decompose-parent-close.sh), since the tickets chained behind a
# split are blocked by the PARENT's number, not by any child's.
# flags/revdep-wake-off puts all of that back to 2026-09-14, byte for byte.
#
# LAUNCHING TRIAGE, NOT JUST UN-BRAKING IT (the operator, 2026-09-14). An issue wake
# once only touched that file, on the argument that a triage session is the most
# expensive thing in the fleet. But "not braked at the NEXT tick" is still up to
# ten minutes of waiting for a cron line, on top of the 6-8 minute
# push-to-anything-noticing gap measured on project-5 on 2026-09-13. So an issue
# wake, and a push to main that released a Blocked-by child, run the project's
# OWN triage tick immediately — the same script the cron line runs. The un-brake
# still happens first: it is what makes the tick we just bought answer RUN
# instead of SKIP queue-unchanged.
#
# EVERY BOX RUNS THIS LOOP FOR ITSELF (BH-2525.2). Until then only the hub ran
# it, and it reached another box's lanes over ssh. Now each box claims the rows
# for the repos bin/box-for.sh places on it (POST /api/wakes/claim) and runs
# their lanes locally; the hub also claims every repo's pr/checks rows, because
# the merge conductor is fleet-wide and hub-only. A claim is keyed (wake, box),
# so it is a per-box dedupe, never a lock: every box gets the same row for its
# own lanes. A row for another box's project is that box's to act on, and here
# it is a log line — never an ssh and never a local launch (the cross-box
# duplicate TK-42 documents). Lanes the registry scopes to the hub are never
# launched off it.
#
# NEVER A SECOND CONCURRENT TRIAGE. Three guards, in cost order: the
# per-(kind,project) cooldown row below stops the launch being paid for at all;
# a push launches only when it has something to work — a released child
# bin/unblocked-children.sh names, or a key the coalescing window held; and
# bin/run-triage.sh takes a per-project flock as its first real act, so a
# launch that races the cron tick logs "previous run still active, skipping"
# and exits — the same collapse two cron ticks already get today.
#
# FAST-PATH FIRST (BH-482). A triage session is still the most expensive thing
# this loop can buy, and a wake whose ticket needs no thinking should not buy
# one — so before the tick, bin/launch-fastpath.sh is asked to launch the keys
# directly, on this box, which owns the project. Per-ticket locks, build dirs
# and checkouts are per box, and launching another box's work from here is the
# cross-box duplicate-build bug TK-42 documents. Its EXIT CODE is the only
# signal read here — 0 means it launched every key and no tick is bought; any
# nonzero (a declined key, a partial launch, a crash, the script missing) falls
# through to the touch + bin/run-triage.sh, unchanged. That is what makes this
# safe to ship ahead of the real script: the contract stub declines everything.
# NO TICK MEANS NO TICK LATER EITHER. The issue loop below has already touched
# state/wake-<project>, and that file alone makes bin/triage-gate.sh answer RUN
# event-wake at the next cron minute — so a fast-path success removes the
# un-brake and the keys file it would have been scoped by. Otherwise the session
# is deferred by ten minutes, not saved.
# flags/fastpath-off stops the call being made at all, as does a box with no
# executable bin/launch-fastpath.sh; the tick is then bought the way it was
# bought before BH-482. The keys are what the fast-path is handed, so a wake
# that names none — every key filtered by key_add, a push whose children could
# not be spelled — calls nothing and buys the tick.
#
# flags/wake-launch-off restores the old behaviour byte for byte: issue wakes
# back to the touch alone, push wakes back to the deploy train alone. It is
# checked before launch_triage is reached at all, so it is also off for the
# fast-path.
#
# DEDUP BEFORE SPEND. Two of those scripts buy metered LLM work (the conductor's
# head-bound re-review, post-merge QA's prodqa lane). A busy repo can ring the
# doorbell many times a minute, so a per-(kind,project) COOLDOWN is taken BEFORE
# anything is launched — at most one launch per lane per WAKE_COOLDOWN_S
# (default 120s) however many rows arrive. The cooldown is a wake_cooldowns row
# the worker grants atomically, shared by every box; anything but taken:true is
# no launch. The wakes are still acked, so the backlog does not grow; they
# simply collapse onto one launch, which is exactly what the lane would have
# done with them anyway since it re-reads GitHub.
#
# THE WATERMARK IS THIS BOX'S wake_cursors ROW. Each claim scans above it, and
# after the launches the loop PUTs the highest row id the claim scanned. The
# claim rows are the guard, not the cursor: a PUT or an ack that fails to land
# re-scans rows this box already claimed, and the worker hands none of them
# back, so no lane runs twice.
#
# HOW IT RUNS. These images have cron and supervisord but no systemd
# (MULTI-MACHINE-PLAN.md, "Known sharp edges"), so the default shape is a
# ONE-MINUTE cron line that polls four times internally — the same 15-second
# pickup bin/poll-commands.sh already gets, and it needs no supervisor, no
# @reboot and no process that can silently die between deploys. Every box runs
# it ungated; the hub's line is behind bin/hub-lease.sh check
# (cron/lanes/020-wake-loop.cron):
#     * * * * * /root/harness/bin/wake-loop.sh
# WAKE_LOOP_CYCLES=0 runs forever instead, for a supervisord [program:] or an
# @reboot line on a box where that is preferred. Either way a single flock means
# two copies can never both be draining the table.
set -uo pipefail
H="${HARNESS:-/root/harness}"
. "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$H")

# >>> lane gate (BH-1165) — one off-switch and one source of numbers for this
# lane. lane_gate_or_exit exits 0 when flags/all-off, flags/lane-off-wake-loop
# (or a pause_flags row driving either) is set; lane_env_apply then puts this
# lane's settings rows into the environment its own ${KNOB:-default} reads use.
# Both fail OPEN: an unreachable worker leaves the lane exactly as it is today.
# Registry: catalog/lanes.json. Operator: bin/harness-ctl.sh off wake-loop.
# shellcheck disable=SC1091
. "${HARNESS:-/root/harness}/bin/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit wake-loop
# BH-2435: fastpath-off is a settings row before it is a file (lane-switch.sh).
. "${HARNESS:-/root/harness}/bin/lib/lane-switch.sh" 2>/dev/null || true
command -v lane_switch >/dev/null 2>&1 || lane_switch() { [ -f "${HARNESS:-/root/harness}/flags/$1" ]; }
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    wake-loop
export HARNESS="$H"
SELF="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$H/logs" "$H/locks" "$H/state" 2>/dev/null || true
LOG="$H/logs/wake-loop.log"
STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
say() { echo "$(STAMP) $*" >> "$LOG"; }

if [ -f "$HENV/global.env" ]; then set -a; # shellcheck disable=SC1091
  . "$HENV/global.env"; set +a; fi
# AND AGAIN, BELOW THE ENV LOAD (BH-1165 review). `set -a; . env/global.env`
# re-assigns every name it carries, so the call above lost each knob the box's
# env file also sets — the settings row was gone, the page went on reporting
# `source: settings`, and nothing errored: the exact shape this ticket exists to
# end. The call above still earns its place: the knobs this lane reads BEFORE
# this line have no other way to see a row. Applying twice is idempotent (the
# settings cache is already warm) and section 16 of tests/lanes-registry-test.sh
# is the ordering.
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    wake-loop
# shellcheck source=bin/jobs-client.sh
[ -r "$SELF/jobs-client.sh" ] && . "$SELF/jobs-client.sh"
# shellcheck source=bin/lib/revdep-lib.sh
[ -r "$SELF/lib/revdep-lib.sh" ] && . "$SELF/lib/revdep-lib.sh"
# BH-1651: closed_diff's list read is REST. gh-rest-list.sh sources gh-rest.sh.
# shellcheck source=bin/lib/gh-rest-list.sh
[ -r "$SELF/lib/gh-rest-list.sh" ] && . "$SELF/lib/gh-rest-list.sh"
# BH-5521: the sha -> open PR lookup for a checks wake pr-state.tsv cannot place.
# Missing lib = wck_sha_prs undefined = every such lookup counts as unread.
# shellcheck source=bin/lib/wake-conductor-keys.sh
[ -r "$SELF/lib/wake-conductor-keys.sh" ] && . "$SELF/lib/wake-conductor-keys.sh"
# BH-8173: a checks sha that is a MAIN sha -> the PRs pending on it in the
# conductor's pre-queue cache whose gate run finished. Missing lib = today's path.
# shellcheck source=bin/lib/wake-prequeue-keys.sh
[ -r "$SELF/lib/wake-prequeue-keys.sh" ] && . "$SELF/lib/wake-prequeue-keys.sh"
# The GitHub-budget reader (#372). OPTIONAL BY DESIGN: a box without the lib, or
# with a partially synced one, must behave exactly as it did before — every use
# below is guarded by `command -v gh_budget_low`.
# shellcheck source=bin/lib/gh-budget.sh
[ -r "$SELF/lib/gh-budget.sh" ] && . "$SELF/lib/gh-budget.sh"
# Lane liveness (BH-638), on the same terms as the libs above: no lib, no change.
# shellcheck source=bin/lib/heartbeat.sh
[ -r "$SELF/lib/heartbeat.sh" ] && . "$SELF/lib/heartbeat.sh"
command -v hb_tick >/dev/null 2>&1 || { hb_start(){ :; }; hb_tick(){ :; }; hb_done(){ :; }; }
command -v wakes_claim >/dev/null 2>&1 || { say "jobs-client.sh unavailable — cron still covers every lane"; exit 0; }

# ── WHO THIS BOX IS, AND WHAT IT OWNS (BH-2525.2) — computed ONCE ────────────
# The box name is lowercased here and nowhere else (D17): the worker compares
# box names case-sensitively and the wake_cursors rows it seeded are lowercase,
# so the claim, the cursor and the cooldown all carry this one spelling.
# shellcheck source=bin/lib/hub-box.sh
[ -r "$SELF/lib/hub-box.sh" ] && . "$SELF/lib/hub-box.sh"
command -v hub_box_name >/dev/null 2>&1 || { say "hub-box.sh unavailable — cron still covers every lane"; exit 0; }
BOX=$("$SELF/box-name.sh" 2>/dev/null | tr 'A-Z' 'a-z')
[ -n "$BOX" ] || { say "box name unresolvable — cron still covers every lane"; exit 0; }
HUB=$(hub_box_name | tr 'A-Z' 'a-z')
IS_HUB=0
{ is_hub_box "$BOX" || [ "$BOX" = "$HUB" ]; } && IS_HUB=1

# owned_here <box-for answer> — is a project placed there run by THIS box? Its
# own name, or `local` (fleet.conf's spelling of "the hub") when this is the hub.
owned_here() {
  local b
  b=$(printf %s "${1:-}" | tr 'A-Z' 'a-z')
  [ -n "$b" ] || return 1
  [ "$b" = "$BOX" ] && return 0
  [ "$b" = local ] && [ "$IS_HUB" = 1 ]
}
OWN_PROJECTS=" "
OWN_REPOS=""
for __wl_p in $("$SELF/fleet-conf.sh" --projects 2>/dev/null); do
  owned_here "$("$SELF/box-for.sh" "$__wl_p" 2>/dev/null | head -1)" || continue
  OWN_PROJECTS="$OWN_PROJECTS$__wl_p "
  __wl_r=$("$SELF/fleet-conf.sh" "$__wl_p" repo 2>/dev/null | tr 'A-Z' 'a-z')
  [ -n "$__wl_r" ] && OWN_REPOS="${OWN_REPOS:+$OWN_REPOS,}$__wl_r"
done
unset __wl_p __wl_r
owns() { case "$OWN_PROJECTS" in *" ${1:-} "*) return 0 ;; esac; return 1; }
# The merge conductor is fleet-wide and hub-only, so only the hub claims every
# repo's pr/checks rows. Only the hub lands lead verdicts, so it also claims
# every repo's lead-land rows (BH-4057).
ALL_KINDS=""
[ "$IS_HUB" = 1 ] && ALL_KINDS="pr,checks,lead-land"
# A claim with no repo and no kind is one the worker refuses (400); a box that
# owns nothing has nothing to ask for.
[ -n "$OWN_REPOS$ALL_KINDS" ] || { say "owns no fleet repo — nothing to claim"; exit 0; }
# How many rows one claim scans. Capped, never dropped: the cursor moves to the
# highest row SCANNED, and whatever the cap left is the next cycle's claim.
CLAIM_LIMIT="${WAKE_CLAIM_LIMIT:-200}"
case "$CLAIM_LIMIT" in
  ''|*[!0-9]*) __wl_bad=1 ;;
  *) __wl_bad=0; { [ "$CLAIM_LIMIT" -ge 1 ] && [ "$CLAIM_LIMIT" -le 500 ]; } || __wl_bad=1 ;;
esac
[ "$__wl_bad" = 1 ] && { say "WAKE_CLAIM_LIMIT='$CLAIM_LIMIT' is not a number in 1..500 — using 200"; CLAIM_LIMIT=200; }
unset __wl_bad

# THE HUB'S LANES STAY ON THE HUB. The wake-class libs `launch` and `cooled`
# lanes the registry scopes to the hub (flaky-detect, prompt-eval,
# fleet-propagate, review-autopilot…); with this loop on every box they would
# fire everywhere. Read once per invocation. Off the hub an unreadable registry
# fails CLOSED for every launch; the hub never asks.
LANE_REG=""
command -v lanes_json_path >/dev/null 2>&1 && { LANE_REG=$(lanes_json_path "$H" 2>/dev/null) || LANE_REG=""; }
[ -n "$LANE_REG" ] || LANE_REG="${LANE_REGISTRY:-$H/catalog/lanes.json}"
HUB_LANES=$(jq -r '.lanes[]? | select(.scope == "hub") | .script, "id:\(.id)"' "$LANE_REG" 2>/dev/null) || HUB_LANES=""
REG_WARNED=0
hub_lane_script() { grep -qxF "bin/${1##*/}" <<<"$HUB_LANES"; }
hub_lane_id() { grep -qxF "id:${1:-}" <<<"$HUB_LANES"; }

# Wake-classes contract (BH-1034). Sourced fail-open: without the lib, or with
# no class files on disk, the loop is byte-for-byte what it was.
# shellcheck source=bin/lib/wake-lanes.sh
[ -r "$SELF/lib/wake-lanes.sh" ] && . "$SELF/lib/wake-lanes.sh"
# Class loader: once per invocation. No class files on disk means WAKE_CLASSES
# is empty and no flag is read. A failed class call must not abort other
# classes or the existing dispatches.
WAKE_CLASSES=()
if [ -d "$SELF/lib" ]; then
  for __wl_class_file in "$SELF/lib"/wake-class-*.sh; do
    [ -r "$__wl_class_file" ] || continue
    __wl_class=${__wl_class_file##*/wake-class-}
    __wl_class=${__wl_class%.sh}
    WAKE_CLASSES+=("$__wl_class")
    # shellcheck source=/dev/null
    . "$__wl_class_file"
  done
fi
# CLASS_ON is checked by class_on(); build it ONCE so flag_active (which may hit
# the network) is called at most once per class per invocation, never per cycle
# and never per row. flags/wake-lanes-off zeroes every entry here, so the kill
# switch costs nothing at the call sites.
declare -A CLASS_ON
__wl_armed=""
for __wl_class in "${WAKE_CLASSES[@]}"; do
  CLASS_ON[$__wl_class]=0
  [ -f "$H/flags/wake-lanes-off" ] && continue
  command -v flag_active >/dev/null 2>&1 || continue
  if flag_active "wake-lanes-${__wl_class}" >/dev/null 2>&1; then
    CLASS_ON[$__wl_class]=1
    __wl_armed="$__wl_armed $__wl_class"
  fi
done
# The one line that tells an operator reading logs/wake-loop.log which classes
# this invocation is actually driving. Silence means none of them are.
[ -n "$__wl_armed" ] && say "wake classes armed:$__wl_armed"

# class_on <class> — the answer built above, never a fresh flag read.
class_on() {
  local class="${1:-}"
  [ -n "$class" ] || return 1
  [ "${CLASS_ON[$class]:-0}" = 1 ]
}
# >>> queue wakes (BH-4059)
# The armed hub claims every `queue` row (a fly build landing in build_queue).
# An unarmed class asks for nothing, so the claim is byte-for-byte
# today's, and rows written while it was unarmed sit below the hub cursor rather
# than replaying in a burst when it is armed.
[ "$IS_HUB" = 1 ] && class_on queue && ALL_KINDS="${ALL_KINDS:+$ALL_KINDS,}queue"
# <<< queue wakes (BH-4059)

exec 9>"$H/locks/wake-loop.lock"
flock -n 9 || exit 0

# --- keep the App installation-token cache warm (2026-09-14, the operator: "every
# throughput ceiling is a bug") ------------------------------------------------
# WHY HERE. bin/gh-token.sh mints a short-lived, repo-scoped GitHub App token so
# the fleet stops sharing one PAT's 5000/h bucket across every box. Minting costs
# two GitHub round-trips, and the last place that should pay for them is the
# critical path of a build or a merge — so the highest-frequency lane on the hub
# refreshes the cache instead, once per invocation (not per cycle). A token lives
# an hour and is refreshed 5 minutes before it expires, so in practice this is one
# mint per repo per ~55 minutes; every other tick reads a warm cache and asks
# GitHub nothing.
# INERT UNLESS ARMED. gh_auth_armed is a file test, so with no env/github-app.env
# (or GH_APP_TOKENS=0, or flags/gh-app-tokens-off) this forks NOTHING and the loop
# is byte-for-byte what it was. It is also fire-and-forget: a slow mint must never
# hold this loop's flock, and every lane falls back to the PAT anyway.
# >>> gh default auth
# shellcheck source=bin/lib/gh-app-auth.sh
[ -r "$SELF/lib/gh-app-auth.sh" ] && . "$SELF/lib/gh-app-auth.sh"
# #469's rate-limit identity line, on the same fail-open terms as the lib above.
# shellcheck source=bin/lib/gh-limit-logger.sh
[ -r "$SELF/lib/gh-limit-logger.sh" ] && . "$SELF/lib/gh-limit-logger.sh"
# <<< gh default auth
if command -v gh_auth_armed >/dev/null 2>&1 && gh_auth_armed && [ -x "$SELF/gh-token.sh" ]; then
  # `9>&-` for the same reason #310 gave the detached re-reviews: a child that
  # inherits this loop's lock fd holds the lock after the loop exits, and the next
  # cron minute finds wake-loop "already running" and drains nothing.
  ( exec 9>&-; setsid "$SELF/gh-token.sh" --warm </dev/null >/dev/null 2>&1 & ) 2>/dev/null
fi

CYCLES="${WAKE_LOOP_CYCLES:-4}"      # 0 = forever (supervisord / @reboot)
INTERVAL="${WAKE_LOOP_INTERVAL_S:-15}"
# The expected-by, DERIVED from the two lines above and never a literal: this
# invocation should be done in CYCLES x INTERVAL plus a 10-minute allowance for
# the lanes a drain launches. CYCLES=0 is the supervisord/@reboot shape — a loop
# that is SUPPOSED to run for ever, so it declares no expected-by at all
# (expect 0 -> deadline 0) rather than a deadline it is meant to blow through.
HB_EXPECT=0
[ "$CYCLES" != 0 ] && HB_EXPECT=$(( CYCLES * INTERVAL + 600 ))
hb_start wake-loop "$INTERVAL" "$HB_EXPECT" "event wakes (every lane still fires on its cron)"
COOLDOWN="${WAKE_COOLDOWN_S:-120}"
# ── HOLDING THE CONDUCTOR INSIDE ONE INVOCATION (BH-373) ────────────────────
# The cooldown above is the brake BETWEEN ticks. This is the brake inside one:
# a cron minute polls four times, and four cycles that each find a fresh pr wake
# used to buy four merge-conductor runs at 40-60 API calls apiece — 19 launches
# an hour on top of the 12 the cron line already pays for. The counter is a
# plain shell variable on purpose: it dies with the process, so the cap is per
# invocation by construction and nothing has to clean it up.
# 0 = unlimited, the fleet's cap convention. A typo is not a cap of zero: it
# falls back to the default and says so, and an explicit number is honoured
# rather than clamped.
CONDUCTOR_CAP="${WAKE_CONDUCTOR_PER_TICK:-1}"
case "$CONDUCTOR_CAP" in
  ''|*[!0-9]*) say "WAKE_CONDUCTOR_PER_TICK='$CONDUCTOR_CAP' is not a number — using 1"; CONDUCTOR_CAP=1 ;;
esac
# KEYED CONDUCTOR LAUNCH (BH-1387). At 1 a drain hands the conductor the PR keys
# it drained, in MC_ONLY_PR, and that run does only those PRs; the cron sweep
# still covers everything. Registered in catalog/lanes.d/wake-loop.json; the
# `:-0` is the documented fallback. Only 0 or 1 — a typo is not an opt-in.
CONDUCTOR_KEYED="${WAKE_CONDUCTOR_KEYED:-0}"
case "$CONDUCTOR_KEYED" in
  0|1) ;;
  *) say "WAKE_CONDUCTOR_KEYED='$CONDUCTOR_KEYED' is not 0 or 1 — using 0"; CONDUCTOR_KEYED=0 ;;
esac
# EVENTS DRIVE KEYED RUNS; THE FULL TICK IS THE SWEEP'S (BH-5521). With the
# keyed launch on, a drain whose wakes name no PR starts NO conductor run at 0:
# the cron sweep (bin/lib/cadence-backstop.sh, hourly) and the 5-minute keyed
# backstop cover it. 1 = the old fall-through to an unkeyed (fleet-wide) run.
# Registered in catalog/lanes.d/wake-loop.json; `:-0` is the fallback.
CONDUCTOR_FULL="${WAKE_CONDUCTOR_FULL:-0}"
case "$CONDUCTOR_FULL" in
  0|1) ;;
  *) say "WAKE_CONDUCTOR_FULL='$CONDUCTOR_FULL' is not 0 or 1 — using 0"; CONDUCTOR_FULL=0 ;;
esac
# How many checks shas per drain may be looked up on GitHub when pr-state.tsv
# cannot place them (one REST read each, wck_sha_prs). 0 = no lookups.
SHA_LOOKUPS="${WAKE_CONDUCTOR_SHA_LOOKUPS:-5}"
case "$SHA_LOOKUPS" in
  ''|*[!0-9]*) say "WAKE_CONDUCTOR_SHA_LOOKUPS='$SHA_LOOKUPS' is not a number — using 5"; SHA_LOOKUPS=5 ;;
esac
# BH-8173: before that lookup, a sha the conductor's pre-queue cache names as
# the main of `pending` entries is mapped to those PRs whose gate run completed
# (wpk_done_prs, one runs read from the same SHA_LOOKUPS budget). 0 = today's
# path. Registered in catalog/lanes.d/wake-loop.json; `:-1` is the fallback.
PREQUEUE_MAIN="${WAKE_CONDUCTOR_PREQUEUE_MAIN:-1}"
case "$PREQUEUE_MAIN" in
  0|1) ;;
  *) say "WAKE_CONDUCTOR_PREQUEUE_MAIN='$PREQUEUE_MAIN' is not 0 or 1 — using 1"; PREQUEUE_MAIN=1 ;;
esac
# The page size of that runs read, 1..100 (wpk_done_prs clamps; registry row
# WAKE_CONDUCTOR_PREQUEUE_PAGE, `:-100` is the fallback).
PREQUEUE_PAGE="${WAKE_CONDUCTOR_PREQUEUE_PAGE:-100}"
CONDUCTOR_LAUNCHED=0
CONDUCTOR_HELD=0
# How far the conductor's window stretches while bin/lib/gh-budget.sh says the
# hour's GitHub budget is nearly spent. Validated for the same reason the cap is,
# and then some: bash reads $((COOLDOWN * abc)) as a multiply by an unset
# variable, which is zero, which would REMOVE the cooldown at exactly the moment
# the budget says to spend less.
STRETCH="${WAKE_BUDGET_STRETCH:-5}"
case "$STRETCH" in
  ''|*[!0-9]*) say "WAKE_BUDGET_STRETCH='$STRETCH' is not a number — using 5"; STRETCH=5 ;;
esac
# A triage tick is the most expensive thing this loop can buy, and the events
# that justify one — a client answering, a blocker merging — arrive at human
# speed. WAKE_TRIAGE_COOLDOWN_S lets an operator widen ONLY that window without
# slowing the doorbell itself; the default is the same 60s.
# ── COALESCING, NOT JUST COOLING DOWN (2026-09-14, the shard storm) ──────────
# WHAT 60s ACTUALLY BOUGHT. The cooldown is per (kind, project) and it DROPS what
# it holds: the wake that loses the race is acked, its key is forgotten, and the
# launch that did happen carries nothing about it. On project-5 the hub drained
# ~110 wakes an hour for one repo and ~13 of them became ticks — the window was
# working — but each of those 13 ticks then adopted the whole board diff, because
# nothing told it WHICH object had rung. A dropped key is what made a wake tick
# indistinguishable from a board-changed tick.
#
# So the window now COALESCES instead of dropping: every wake's key goes into a
# per-project pending list the moment it is read, and the launch that eventually
# fires carries the UNION of everything pending. A wake held back is not a wake
# lost — it is the next tick's scope. WAKE_COALESCE_S (default 120, twice the old
# window, because a tick that carries its keys is worth waiting a little longer
# for) is that window; WAKE_TRIAGE_COOLDOWN_S still overrides it by hand.
# flags/wake-coalesce-off restores the 2026-09-13 behaviour byte for byte: the
# WAKE_COOLDOWN_S window, no key list, and a tick that scopes itself off the diff.
COALESCE_ON=1
[ -f "$H/flags/wake-coalesce-off" ] && COALESCE_ON=0
if [ "$COALESCE_ON" = 1 ]; then
  COALESCE="${WAKE_COALESCE_S:-120}"
  TRIAGE_COOLDOWN="${WAKE_TRIAGE_COOLDOWN_S:-$COALESCE}"
else
  TRIAGE_COOLDOWN="${WAKE_TRIAGE_COOLDOWN_S:-$COOLDOWN}"
fi
KEYDIR="$H/state/wake-keys"
# How far back a push wake looks for "what did this merge close". The row
# carries a head sha and nothing else (docs/EVENTS.md §3, identifiers only), so
# the close timestamps are what answers it; the window only has to cover the
# doorbell's own latency, not a cron cadence.
PUSH_WINDOW="${WAKE_PUSH_WINDOW_S:-900}"
# A kill switch that needs no deploy: the file is the flag, like every other
# pause in this fleet. With it present the loop drains nothing and the cron
# cadence is all that is left, which is where the fleet was yesterday.
PAUSE="$H/flags/wake-loop-off"
# The kill flag for the triage launch ALONE (the operator, 2026-09-14). With it present
# an issue wake goes back to touching state/wake-<project> and nothing else, and
# a push wake back to asking the deploy train and nothing else — the loop of
# 2026-09-13, byte for byte. PAUSE above still stops the whole drain.
LAUNCH_OFF="$H/flags/wake-launch-off"
# The kill switch for the FAST-PATH alone (BH-482, header above) is fastpath-off,
# read by fp_on below (BH-2435: the settings row, then flags/fastpath-off). With
# it on both arms below emit exactly the command they emitted yesterday, byte for
# byte, and bin/launch-fastpath.sh is not called at all — the tick is bought the
# way it has been bought since 2026-09-14.
# ── THE OTHER DIRECTION OF A CLOSURE (the operator, 2026-09-15) ──────────────────────
# Every wake names the object that MOVED, and a closure's whole point is the
# tickets it RELEASED — the ones whose bodies say `Blocked-by: #<it>`. Nothing
# here ever looked that way round: #721's three blockers closed at 05:33Z and
# #721 never launched, #671 waited on a #670 that had been closed by hand.
# bin/lib/revdep-lib.sh carries the closure to bin/unblocked-children.sh, which
# has known how to answer "who does this release" since TK-332. Off (or without
# the lib) this is the loop of 2026-09-14, byte for byte.
RD_ON=0
if command -v revdep_on >/dev/null 2>&1; then RD_ON=$(revdep_on "$H"); fi

# key_add <project> <key>... — remember what this wake was about, so the launch
#   that eventually fires can scope its tick to it. A FILE rather than a shell
#   variable because the coalescing window spans DRAINS and cron minutes, not
#   just one pass of the loop.
#
#   Sanitised on the way in, hard: these strings become part of a remote shell
#   command and a filename on the owning box. Anything outside [A-Za-z0-9._-] or
#   longer than a ticket key is dropped rather than escaped — a key we cannot
#   name is a key the tick simply will not be scoped to, which costs one board
#   diff, and the same rule bin/lib/triage-shards-lib.sh:triage_shard_canon uses.
key_add() {
  local p="$1" k
  shift
  [ "$COALESCE_ON" = 1 ] || return 0
  [ -f "$LAUNCH_OFF" ] && return 0
  mkdir -p "$KEYDIR" 2>/dev/null || return 0
  for k in "$@"; do
    case "$k" in ''|'-'|*[!A-Za-z0-9._-]*) continue ;; esac
    [ "${#k}" -le 48 ] || continue
    printf '%s\n' "$k" >> "$KEYDIR/pending-$p" 2>/dev/null || true
  done
  return 0
}

# key_take <project> — print the union of everything pending for this project and
#   clear it. Called only when the cooldown has ALREADY been taken, so the keys
#   leave the list exactly once, with the launch that will carry them. Two copies
#   of this loop can never both be here (one flock, taken at the top).
key_take() {
  local f="$KEYDIR/pending-$1"
  [ -s "$f" ] || return 1
  awk '!seen[$0]++' "$f" 2>/dev/null | head -50
  rm -f "$f" 2>/dev/null || true
  return 0
}

# key_pending <project> — how many keys are waiting out the window, for the log.
key_pending() {
  local f="$KEYDIR/pending-$1"
  [ -s "$f" ] && { awk '!seen[$0]++' "$f" 2>/dev/null | grep -c .; return 0; }
  printf '0\n'
}

# repo_project <owner/repo> — which fleet.conf project owns this repo, if any.
# THE REGISTRY IS THE ONLY SOURCE. A repo no project claims is acked and dropped:
# the org webhook is org-wide on purpose (one hook, no per-repo bookkeeping), so
# deliveries for repos the fleet does not run are the normal case, not an error.
_RP_CACHE=""
repo_project() {
  local slug="$1" p r
  if [ -z "$_RP_CACHE" ]; then
    _RP_CACHE=$(for p in $("$SELF/fleet-conf.sh" --projects 2>/dev/null); do
      r=$("$SELF/fleet-conf.sh" "$p" repo 2>/dev/null) || continue
      [ -n "$r" ] && printf '%s\t%s\n' "$(printf %s "$r" | tr 'A-Z' 'a-z')" "$p"
    done)
    [ -n "$_RP_CACHE" ] || _RP_CACHE="-"
  fi
  [ "$_RP_CACHE" = "-" ] && return 1
  p=$(awk -v s="$(printf %s "$slug" | tr 'A-Z' 'a-z')" -F'\t' '$1==s {print $2; exit}' <<<"$_RP_CACHE")
  [ -n "$p" ] || return 1
  printf '%s' "$p"
}

# cooled <kind> <project> [window] — rc 0 when this lane may be launched NOW.
# The (kind, project) cooldown is a wake_cooldowns ROW, shared by every box and
# taken atomically by the worker, so two boxes — or two rows in one cycle —
# cannot both pass. Which box may take it is decided here first, with no
# request: a fleet-wide lane is the hub's; a hub-scoped lane never fires on a
# box; and another box's project is taken only for a lane this box's own
# crontab runs for it (or a hub lane, on the hub) — otherwise the hub would take
# the row, decline to launch, and leave the owning box `taken:false` for ever.
# Anything but taken:true is no launch: cron covers every lane.
COOL_WARNED=" "
COOL_NOTED=" "
cool_note() { # cool_note <key> <line> — once per key per invocation
  case "$COOL_NOTED" in *" $1 "*) return 0 ;; esac
  COOL_NOTED="$COOL_NOTED$1 "
  say "$2"
}
cooled() {
  local kind="${1:-}" p="${2:-}" win="${3:-$COOLDOWN}" owner rc
  if [ "$p" = fleet ]; then
    [ "$IS_HUB" = 1 ] || { cool_note "${kind}[fleet]" "${kind}[fleet]: fleet-wide lane — the hub's loop takes it"; return 1; }
  elif [ "$IS_HUB" != 1 ] && hub_lane_id "$kind"; then
    cool_note "${kind}[$p]" "${kind}[$p]: hub lane — the hub's loop takes it"; return 1
  elif ! owns "$p"; then
    if ! lane_runs_here "$kind" "$p" && ! { [ "$IS_HUB" = 1 ] && hub_lane_id "$kind"; }; then
      owner=$("$SELF/box-for.sh" "$p" 2>/dev/null | head -1)
      cool_note "${kind}[$p]" "${kind}[$p]: owned by ${owner:-no box} — its own loop takes this cooldown"
      return 1
    fi
  fi
  wake_cooldown_take "$kind" "$p" "$win" "$BOX"; rc=$?
  case "$rc" in 0) return 0 ;; 1) return 1 ;; esac
  case "$COOL_WARNED" in
    *" ${kind}[$p] "*) ;;
    *) COOL_WARNED="$COOL_WARNED${kind}[$p] "; say "cooldown row unreachable — cron covers ${kind}[$p]" ;;
  esac
  return 1
}

# launch <label> <cmd...> — detached, always. bin/deploy-train.sh polls a
# version endpoint for up to ~13 minutes and bin/postmerge-qa.sh drives a
# browser; running either in the foreground would hold the loop's flock across
# the whole thing and turn a 15-second doorbell into a quarter-hour deaf spot.
# Each target has its own flock, so a concurrent cron tick of the same lane is
# already a clean no-op — this loop does not need to (and must not) coordinate
# with cron beyond that.
#
# Off the hub it refuses a lane the registry scopes to the hub (header above).
launch() {
  local label="$1"; shift
  [ -x "$1" ] || { say "$label: $1 is not executable — skipped"; return 1; }
  if [ "$IS_HUB" != 1 ]; then
    if [ -z "$HUB_LANES" ]; then
      [ "$REG_WARNED" = 1 ] || say "lane registry unreadable ($LANE_REG) — nothing launched on $BOX (cron covers every lane)"
      REG_WARNED=1
      return 1
    fi
    if hub_lane_script "$1"; then
      say "$label: $(basename "$1") is a hub lane — not launched on $BOX (cron on the hub covers it)"
      return 1
    fi
  fi
  ( WAKE_LAUNCH=1 setsid "$@" </dev/null >/dev/null 2>&1 & ) 2>/dev/null
  say "$label: launched $(basename "$1") ${2:-}"
}

# fp_on <key>... — may this launch try the fast-path? ONE definition for both
# arms, because a gate that is spelled twice is a gate that drifts: no keys means
# nothing to hand it, fastpath-off is the operator's off switch, and a hub whose copy
# of the script is missing or not executable asks for nothing (which is also why
# every fixture that copies only the scripts it names keeps seeing yesterday's
# loop).
fp_on() { [ "$#" -gt 0 ] && ! lane_switch fastpath-off file && [ -x "$SELF/launch-fastpath.sh" ]; }

# ── LAUNCH THE WORK, NOT JUST THE BRAKE (the operator, 2026-09-14; header above) ─────
# Everything from here to drain() is the triage launch, and none of it is
# reached when flags/wake-launch-off exists.

# closed_diff <repo> — bin/gate-diff.sh-shaped lines for every ai-build issue in
# <repo> that went OPEN -> CLOSED inside the last PUSH_WINDOW seconds, which is
# the input bin/unblocked-children.sh reads. A push wake carries a head sha and
# nothing else, so "what did this merge close" is not in the row — but it is a
# FREE gh lookup, and the close timestamps answer it deterministically without
# believing a word of the delivery. Prints nothing on any problem (no gh, no jq,
# an unreachable API, a repo that has never used the ai-build label), and
# nothing is exactly what makes the caller fall back to today's behaviour.
closed_diff() {
  local cut t
  command -v gh >/dev/null 2>&1 || return 0
  command -v jq >/dev/null 2>&1 || return 0
  cut=$(( $(date +%s) - PUSH_WINDOW ))
  t=$(mktemp "${TMPDIR:-/tmp}/wake-closed.XXXXXX") || return 0
  if command -v gh_rest_issue_list >/dev/null 2>&1 && gh_rest_issue_list "$1" closed ai-build 50 > "$t"; then
    jq -r --argjson cut "$cut" '
        .[]? | select(.closed_at != null)
             | select((.closed_at | try fromdateiso8601 catch 0) >= $cut)
             | "board issues: CHANGED \(.number) \"\" (state: open -> closed)"' "$t" 2>/dev/null
  fi
  rm -f "$t"
  # AND WHAT THE MERGES THEMSELVES CLOSED (2026-09-15). The list above is
  # `--label ai-build`, and the issue a merge closes is very often not in it: a
  # decomposed parent has had the label stripped, and an issue closed by
  # GitHub's own `closes #N` keyword may never have carried it. The PR says so
  # itself, so ask it — one extra list on a path that is already behind the
  # triage cooldown. Duplicates with the line above are free: the reader sorts
  # the closure set.
  [ "$RD_ON" = 1 ] || return 0
  command -v revdep_merged_closes >/dev/null 2>&1 || return 0
  # shellcheck disable=SC2046  # numbers by construction (revdep_merged_closes)
  revdep_diff_lines $(revdep_merged_closes "$1" "$PUSH_WINDOW")
  return 0
}

# push_children <project> — rc 0 when this merge released a Blocked-by child,
# which is the only thing about a push that a triage tick can act on: the
# conductor and the deploy train already own the rest of a merge's aftermath.
# What nothing owned was the child ticket that became buildable the moment its
# blocker closed — TK-332 sat 3.5 h that way on 2026-09-12, which is the
# incident bin/unblocked-children.sh was written for. In-app board projects
# have no Blocked-by convention, so that script prints nothing for them and a
# push there launches no triage at all.
# It also PRINTS the child ticket keys (2026-09-14): those children ARE what the
# tick it buys should work, and a push wake's own row carries only a head sha, so
# without this the tick had nothing to scope itself to and took the whole board
# diff instead. Same line shape bin/gate-diff.sh writes, so the key is the third
# field of `board <list>: <CLASS> <key> ...`.
# Since 2026-09-15 the expansion itself lives in released_by() below, because an
# issue wake that turns out to be a CLOSE needs exactly the same answer and had
# no way to ask for it.
push_children() {
  local p="$1" repo nums
  repo=$("$SELF/fleet-conf.sh" "$p" repo 2>/dev/null) || return 1
  [ -n "$repo" ] || return 1
  # >>> gh default auth
  # The identity for THIS repo's one `gh` lookup (BH-470, #424).
  command -v gh_default_auth_for_project >/dev/null 2>&1 && { gh_default_auth_for_project "$p" || true; }
  # <<< gh default auth
  nums=$(closed_diff "$repo" | sed -nE 's/^board [^:]+: CHANGED ([0-9]+).*/\1/p' | sort -un)
  # >>> gh default auth reset
  # AND RESET IT IMMEDIATELY. This loop `launch`es other lanes, and a child that
  # inherited repo A's installation token as its PROCESS DEFAULT would
  # gh_auth_reset back to A's token instead of the box's PAT.
  command -v gh_default_auth_reset >/dev/null 2>&1 && gh_default_auth_reset
  # <<< gh default auth reset
  [ -n "$nums" ] || return 1
  # shellcheck disable=SC2086  # numbers by construction
  released_by "$p" push $nums
}

# issue_closures <project> <key>... — of the objects this wake named, the ones
# that are CLOSED on GitHub right now.
#
# THE ROW CANNOT TELL US. docs/EVENTS.md §3: the receiver keeps identifiers and
# nothing else, on purpose — no state, no action, no "merged: true" — so an
# `issues` delivery for a close and one for an edit arrive identical. The state
# is one free lookup per key, and it is the difference between a tick scoped to
# the ticket that closed and a tick that also carries everything that ticket
# released. A key we cannot read is not a closure: an expansion that guesses
# costs a build, one that waits costs a tick.
issue_closures() {
  local p="$1" repo bp k n; shift
  [ "$RD_ON" = 1 ] || return 1
  command -v revdep_issue_state >/dev/null 2>&1 || return 1
  # GitHub-Issues boards only, and the registry is how we know: board prefix "-"
  # is the lane bin/load-project.sh onboards that way. An in-app board has no
  # Blocked-by convention for a closure to release anything through, so asking
  # GitHub about its issues would be one round trip to learn nothing.
  bp=$("$SELF/fleet-conf.sh" "$p" board_prefix 2>/dev/null) || return 1
  [ "$bp" = "-" ] || return 1
  repo=$("$SELF/fleet-conf.sh" "$p" repo 2>/dev/null) || return 1
  [ -n "$repo" ] || return 1
  for k in "$@"; do
    # `TK-721` and `721` are one ticket on a GitHub-Issues board; the webhook
    # spells it bare, a lane ringing the doorbell by hand may not.
    n="${k##*-}"
    case "$n" in ''|*[!0-9]*) continue ;; esac
    [ "$(revdep_issue_state "$repo" "$n" 2>/dev/null)" = CLOSED ] || continue
    printf '%s\n' "$n"
  done
  return 0
}

# released_by <project> <why> <closed-number>... — rc 0 + the ticket keys these
# closures make launchable, in bin/unblocked-children.sh's own vocabulary.
#
# ONE PASS FOR BOTH HALVES OF THE 2026-09-15 GAP:
#   * a decompose parent whose every child has merged is closed FIRST, because
#     the tickets waiting on that split are blocked by the PARENT's number and
#     not by any child's (#671 -> #670). Its number then rides in the same
#     closure set as everything else that closed.
#   * the closure set is written where the OWNING BOX's own dependency pass will
#     read it (state/wake-closed-<project>, on this box, which owns it). The keys this
#     prints scope the tick; that file is what makes the tick's own pass emit the
#     UNBLOCKED line even when the ai-build fingerprint could never carry the
#     closure into a diff.
released_by() {
  local p="$1" lane="$2" nums parents kids lines n
  shift 2
  nums="$*"
  if [ "$RD_ON" = 1 ] && [ -x "$SELF/decompose-parent-close.sh" ]; then
    parents=$("$SELF/decompose-parent-close.sh" "$p" --cooled 2>/dev/null \
                | grep -E '^[0-9]{1,9}$' | head -10)
    if [ -n "$parents" ]; then
      # Flattened to one line: this string is a log entry and a closure set, and
      # both read badly with the newlines grep left in them.
      parents=$(tr '\n' ' ' <<<"$parents")
      say "${lane}[$p]: closed decompose parent(s) ${parents}— every child of the split had merged"
      nums="$nums $parents"
    fi
  fi
  [ -n "${nums// /}" ] || return 1
  # The closure the OWNING BOX's own pass will read — this box (one-shot, taken
  # by the tick). Best effort: the keys below scope the tick either way.
  if [ "$RD_ON" = 1 ] && command -v revdep_note_closed >/dev/null 2>&1; then
    # shellcheck disable=SC2086  # numbers by construction
    revdep_note_closed "$H" "$p" $nums || true
  fi
  # Spelled here rather than assumed from the lib: a tree without
  # bin/lib/revdep-lib.sh must hand this pass a REAL closure line, never an
  # empty stdin — an empty stdin is a different question with a different answer.
  lines=""
  for n in $nums; do
    case "$n" in ''|*[!0-9]*) continue ;; esac
    lines="${lines:+$lines
}board issues: CHANGED $n \"\" (state: open -> closed)"
  done
  [ -n "$lines" ] || return 1
  # REVDEP_TAKE=0: the closures are on stdin already, and consuming
  # state/wake-closed-<project> here would eat the copy the tick this wake is
  # about to launch needs for its own dependency pass.
  kids=$(REVDEP_TAKE=0 "$SELF/unblocked-children.sh" "$p" <<<"$lines" 2>/dev/null) || return 1
  [ -n "$kids" ] || return 1
  say "${lane}[$p]: $(grep -c . <<<"$kids") ticket(s) released by the close of #$(printf '%s' "${nums# }" | tr ' ' ',')"
  if command -v revdep_keys >/dev/null 2>&1; then
    printf '%s\n' "$kids" | revdep_keys
  else
    printf '%s\n' "$kids" | sed -nE 's/^board [^:]+: [A-Z]+ ([A-Za-z0-9._-]+).*/\1/p' | awk '!seen[$0]++'
  fi
  return 0
}

# launch_triage <project> <why> — run THIS project's triage tick now, when this
# box owns it. FAILS CLOSED on an unknown owner, and another box's project is
# only a log line: running another box's triage is the cross-box duplicate-build
# bug bin/poll-commands.sh documents (TK-42, twin PRs 2026-07-25) — per-ticket
# locks are per-box and cannot dedupe across machines — and that box's own loop
# claims the same wake for itself.
launch_triage() {
  local p="$1" why="$2" box
  shift 2
  box=$("$SELF/box-for.sh" "$p" 2>/dev/null | head -1)
  [ -n "$box" ] || { say "triage[$p]: fleet.conf names no box for this project — not launched ($why)"; return 0; }
  owned_here "$box" || { say "triage[$p]: owned by $box — its own loop claims this wake"; return 0; }
  # Two writes, in this order: the keys the tick will scope itself to,
  # then the one-shot un-brake that makes the gate answer RUN instead of
  # SKIP. Written before the launch, because bin/run-triage.sh reads and
  # consumes both as its first real act.
  if [ "$#" -gt 0 ]; then printf '%s\n' "$@" > "$H/state/wake-keys-$p" 2>/dev/null || true
  else rm -f "$H/state/wake-keys-$p" 2>/dev/null || true; fi
  # THE FAST PATH (BH-482, header above), here because this box IS the
  # owning box. After the keys file so a fall-through finds it written, and
  # before the un-brake so a launch that needed no session buys the tick.
  # This arm already runs inside the detached subshell the drain loop
  # starts, so the fast-path's own synchronous work never holds the
  # doorbell. Nonzero is nonzero: the tick below is bought whatever went
  # wrong, and only exit 0 is ever reported as launched.
  #
  # AND IT TAKES BACK THE TICK'S EXCUSE. Not touching state/wake-$p here
  # is not enough: drain()'s issue pass ran before this one and touched
  # it for every issue wake in the batch, and bin/triage-gate.sh answers
  # `RUN event-wake` on that file alone — so a fast-path that launched
  # every key would still have bought a full session at the next cron
  # minute, scoped by the keys file to the very ticket it just launched.
  # Deferring the spend is not skipping it. Both one-shot files go, in
  # the reverse of the order they are written.
  # A wake that lands for this project while the fast-path is still
  # running re-touches the un-brake and can lose it to this rm; its key
  # is in the pending list either way, and the launch past the
  # coalescing window writes both files again.
  if fp_on "$@" && "$SELF/launch-fastpath.sh" "$p" "$@" >/dev/null 2>&1; then
    rm -f "$H/state/wake-$p" "$H/state/wake-keys-$p" 2>/dev/null || true
    say "fastpath[$p]: every key launched ($why, keys=$*) — no triage tick bought"
    return 0
  fi
  touch "$H/state/wake-$p" 2>/dev/null || true
  launch "triage[$p] ($why, keys=${*:-none})" "$SELF/run-triage.sh" "$p"
}

# lane_runs_here <script> <project> — does THIS box's crontab drive that lane for
# that project? It reads `crontab -l`, the ROOT USER crontab, because that is
# where the fleet puts its lanes: bin/bootstrap-machine.sh renders cron/<box>.cron
# and installs it with `crontab "$CRONTMP"`, and bin/cli-version-check.sh reads
# it back the same way. /etc/crontab is a different
# file, with a user column, that nothing in this fleet writes — reading it can
# only ever answer "no", which would leave every other box's lane to its owner
# even where this box's crontab already runs it.
lane_runs_here() {
  local script="${1:-}" project="${2:-}" lines
  [ -n "$script" ] && [ -n "$project" ] || return 1
  # Captured before the grep so `crontab -l` failing (no crontab installed)
  # cannot be read as a match under `set -o pipefail`.
  lines=$(crontab -l 2>/dev/null) || return 1
  [ -n "$lines" ] || return 1
  grep -qE "/bin/${script}(\.sh)? +${project}( |\$)" <<<"$lines"
}

# remote_launch <label> <project> <script> [args…] — run a lane for <project>
# here, when this box owns the project or its own crontab already drives that
# lane for it. Anything else is another box's: that box's own loop claims the
# same wake, and its cron covers it regardless, so this is a log line and never
# a launch — the cross-box duplicate the per-ticket locks cannot dedupe (TK-42,
# and the reason launch_triage above fails closed). The name and signature are
# the wake-class libs' contract, unchanged.
remote_launch() {
  local label="${1:-}" p="${2:-}" script="${3:-}" box
  [ -n "$label" ] && [ -n "$p" ] && [ -n "$script" ] || return 1
  shift 3
  box=$("$SELF/box-for.sh" "$p" 2>/dev/null | head -1)
  [ -n "$box" ] || { say "$label: fleet.conf names no box for $p — not launched"; return 1; }
  if owned_here "$box" || lane_runs_here "$script" "$p"; then
    launch "$label" "$SELF/$script" "$@"
    return
  fi
  say "$label: owned by $box — its own loop claims this wake"
  return 0
}

# ── THE WATERMARK IS THIS BOX'S wake_cursors ROW (BH-2525.2) ────────────────
# LAST_PUT is the value the row is known to hold, so a quiet box makes no
# cursor request per cycle. SEEDED is set once the first-cutover question below
# has an answer.
LAST_PUT=0
SEEDED=0
SEED_WARNED=0
CLAIM_WARNED=0

# seed_cursor — once per invocation, before the first claim. A box with no
# cursor row has never claimed (only the hub ran this loop before BH-2525.2, and
# the schema seeded rows only from the hub's settings mirror), so it adopts the
# hub's watermark once rather than claiming thirty days of backlog and launching
# a triage session and a deploy train per stale row. No hub row either: from 0,
# which is where the loop always started. rc 1 = could not tell (a GET was
# unusable), and then nothing is claimed this cycle: an unreadable cursor is
# never read as "no cursor".
seed_cursor() {
  local own hubc
  if ! own=$(wake_cursor_get "$BOX"); then
    [ "$SEED_WARNED" = 1 ] || say "cursor row unreadable — nothing claimed until it answers (cron covers every lane)"
    SEED_WARNED=1; return 1
  fi
  case "$own" in
    '') ;;
    *[!0-9]*) return 1 ;;
    *) LAST_PUT="$own"; SEEDED=1; return 0 ;;
  esac
  if [ "$HUB" != "$BOX" ]; then
    if ! hubc=$(wake_cursor_get "$HUB"); then
      [ "$SEED_WARNED" = 1 ] || say "the hub's cursor row is unreadable — nothing claimed until it answers (cron covers every lane)"
      SEED_WARNED=1; return 1
    fi
    case "$hubc" in
      ''|*[!0-9]*) ;;
      *) wake_cursor_put "$BOX" "$hubc" || { say "cursor seed put failed at $hubc — retried next cycle"; return 1; }
         LAST_PUT="$hubc"; SEEDED=1
         say "cursor seeded from the hub's: $hubc"
         return 0 ;;
    esac
  fi
  say "no cursor row for $BOX or the hub — claiming from 0"
  SEEDED=1
  return 0
}

# cursor_move <scanned_top> — PUT the watermark when it moved. After the
# launches and BEFORE the ack. A failed PUT is a log line: the next claim
# re-scans the same rows and the claim rows (wake_id, box) hand back none of
# them, so nothing launches twice.
cursor_move() {
  local n="${1:-}"
  case "$n" in ''|*[!0-9]*) return 0 ;; esac
  [ "$n" -gt "$LAST_PUT" ] || return 0
  if wake_cursor_put "$BOX" "$n"; then LAST_PUT="$n"
  else say "cursor put failed at $n — the claim rows still dedupe"; fi
}

# ── A CONDUCTOR RUN THIS LOOP COULD NOT LAUNCH IS OWED (BH-3453) ─────────────
# A pr/checks wake held by the per-invocation cap, or refused by the pr/fleet
# cooldown (taken:false or unreachable), used to be acked and forgotten, and the
# conductor cron is */30 since BH-1389, so the PR it named waited that long for
# nobody (project-5#3415). The debt is a plain file: one owner/repo#n per line,
# or `*` for a wake that named no key. This loop is single-copy under its flock,
# so it has one writer and one reader and needs no lock of its own.
OWED="$H/state/wake-conductor-owed"

# conductor_window — the pr/fleet window, stretched when the GitHub hour is
# nearly spent. rc 1 (healthy) and rc 2 (unknown) both leave it alone: an
# unreadable budget must never be what slows the fleet down. One definition for
# the batch launch and the owed pay, so the two cannot drift.
conductor_window() {
  if command -v gh_budget_low >/dev/null 2>&1 && gh_budget_low wake-loop; then
    echo $(( COOLDOWN * STRETCH ))
  else
    echo "$COOLDOWN"
  fi
}

# conductor_owe <keys,csv> <all 0|1> <why> — record the run this drain wanted
# and did not launch. A failed write is a line, not a stop: the wake is acked
# either way, and the cron tick still covers it.
conductor_owe() {
  local keys="$1" all="$2" why="$3" n
  # BH-5521: a batch that named no PR owes no full tick; the sweep covers it.
  if [ "$CONDUCTOR_FULL" = 0 ] && [ "$CONDUCTOR_KEYED" = 1 ] && [ "$all" = 0 ] && [ -z "$keys" ]; then return 0; fi
  if [ "$all" = 0 ] && [ -n "$keys" ]; then
    n=$(tr ',' '\n' <<<"$keys" | grep -c .)
    tr ',' '\n' <<<"$keys" 2>/dev/null >> "$OWED"
  else
    n=1
    echo '*' 2>/dev/null >> "$OWED"
  fi || { say "pr/checks: owed marker write failed — cron covers it"; return 0; }
  say "pr/checks: conductor run owed — $n line(s) in state/wake-conductor-owed ($why)"
}

# conductor_owed_pay — once per drain, before the empty-drain return. The file
# is moved away BEFORE the launch, so a debt pays once; a launch that cannot
# start puts its lines back; a refused cooldown leaves the file for next time.
# The pay counts against the per-invocation cap like any other launch.
conductor_owed_pay() {
  [ "$IS_HUB" = 1 ] && [ -s "$OWED" ] || return 0
  if [ "$CONDUCTOR_CAP" != 0 ] && [ "$CONDUCTOR_LAUNCHED" -ge "$CONDUCTOR_CAP" ]; then return 0; fi
  if [ "$CONDUCTOR_FULL" = 0 ] && [ "$CONDUCTOR_KEYED" = 1 ]; then conductor_owed_pay_keyed; return 0; fi
  cooled pr fleet "$(conductor_window)" || return 0
  local take="$OWED.taking.$$" keys rc
  mv -f "$OWED" "$take" 2>/dev/null || return 0
  keys=$(awk 'NF && !seen[$0]++' "$take")
  # Past 50 keys the launch goes unkeyed rather than dropping any (key_take's
  # ceiling); a `*` or the knob off is today's fleet-wide launch.
  if [ "$CONDUCTOR_KEYED" != 1 ] || grep -qx '\*' <<<"$keys" || [ "$(grep -c . <<<"$keys")" -gt 50 ]; then
    launch "pr/checks owed" "$SELF/merge-conductor.sh"; rc=$?
  else
    ( export MC_ONLY_PR="$(paste -sd, <<<"$keys")"
      launch "pr/checks owed[$MC_ONLY_PR]" "$SELF/merge-conductor.sh" ); rc=$?
  fi
  if [ "$rc" = 0 ]; then CONDUCTOR_LAUNCHED=$((CONDUCTOR_LAUNCHED+1))
  else cat "$take" >> "$OWED" 2>/dev/null; fi
  rm -f "$take"
}

# conductor_owed_pay_keyed — the owed pay under WAKE_CONDUCTOR_FULL=0 (BH-5521):
# never an unkeyed launch. A `*` line is dropped (the sweep covers it). The key
# count is read BEFORE the cooldown, so an empty debt never burns the window. A
# debt past 50 keys (key_take's ceiling) launches the first 50 and puts the
# rest back for the next cycle.
conductor_owed_pay_keyed() {
  local keys stars n rest="" take="$OWED.taking.$$" rc
  keys=$(awk 'NF && !seen[$0]++' "$OWED" 2>/dev/null)
  stars=$(grep -cx '\*' <<<"$keys")
  keys=$(grep -vx '\*' <<<"$keys")
  n=$(grep -c . <<<"$keys")
  if [ "$n" = 0 ]; then
    rm -f "$OWED"
    [ "$stars" -gt 0 ] && say "pr/checks owed: $stars unkeyed line(s) dropped — the hourly sweep covers them"
    return 0
  fi
  cooled pr fleet "$(conductor_window)" || return 0
  mv -f "$OWED" "$take" 2>/dev/null || return 0
  [ "$stars" -gt 0 ] && say "pr/checks owed: $stars unkeyed line(s) dropped — the hourly sweep covers them"
  if [ "$n" -gt 50 ]; then rest=$(tail -n +51 <<<"$keys"); keys=$(head -n 50 <<<"$keys"); fi
  ( export MC_ONLY_PR="$(paste -sd, <<<"$keys")"
    launch "pr/checks owed[$MC_ONLY_PR]" "$SELF/merge-conductor.sh" ); rc=$?
  if [ "$rc" = 0 ]; then
    CONDUCTOR_LAUNCHED=$((CONDUCTOR_LAUNCHED+1))
    if [ -n "$rest" ]; then
      printf '%s\n' "$rest" >> "$OWED" 2>/dev/null
      say "pr/checks owed: $(grep -c . <<<"$rest") key(s) past 50 put back for the next cycle"
    fi
  else
    { printf '%s\n' "$keys"; [ -n "$rest" ] && printf '%s\n' "$rest"; } >> "$OWED" 2>/dev/null
  fi
  rm -f "$take"
}

drain() {
  [ -f "$PAUSE" ] && return 0
  local ids=() rows n=0 scanned_top
  [ "$SEEDED" = 1 ] || seed_cursor || return 0
  # THE CLAIM (BH-2525.2). The worker scans above this box's cursor for rows in
  # the repos this box owns (plus every repo's pr/checks on the hub) and hands
  # back only the ones this box had not claimed yet — a per-box dedupe, not a
  # lock, so every box still gets the same wake for its own lanes. An unusable
  # answer is no rows, no launch, no cursor move and no ack.
  if ! rows=$(wakes_claim "$BOX" "$CLAIM_LIMIT" "$OWN_REPOS" "$ALL_KINDS"); then
    [ "$CLAIM_WARNED" = 1 ] || say "claim unavailable — cron covers every lane"
    CLAIM_WARNED=1
    return 0
  fi
  scanned_top=$(sed -n 's/^#top //p' <<<"$rows" | tail -1)
  rows=$(grep -v '^#top ' <<<"$rows")
  conductor_owed_pay
  # >>> queue wakes (BH-4059): a fly launch an earlier invocation held, paid here
  # so it runs on an empty drain too (bin/lib/wake-class-queue.sh).
  class_on queue && command -v wc_queue_owed_pay >/dev/null 2>&1 && wc_queue_owed_pay || true
  # <<< queue wakes (BH-4059)
  [ -n "$rows" ] || { cursor_move "$scanned_top"; return 0; }
  # ONE PASS TO CLASSIFY, THEN LAUNCH. Every row is read first so that twenty
  # presses on one PR become one conductor run, not twenty racing ones.
  local want_conductor=0 conductor_prs="" conductor_all=0 sha_q="" lrepo="" pc_n=0 push_projects="" deploy_projects="" issue_projects=""
  local dropped="" dropped_n=0 foreign="" foreign_n=0
  local want_lead_review=0 want_lead_land=0
  local id repo kind key event at project
  while IFS=$'\t' read -r id repo kind key event at; do
    [ -n "${id:-}" ] || continue
    n=$((n+1)); ids+=("$id")
    # >>> queue wakes (BH-4059). Its repo is the worker's synthetic
    # `harness/build-queue`, which repo_project below would drop as "not a fleet
    # repo", so the class gets the row here and the generic paths never see it.
    # Off the hub, or unarmed, the row is acked and nothing launches.
    case "$kind" in
      queue) [ "$IS_HUB" = 1 ] && class_on queue && command -v wc_queue_row >/dev/null 2>&1 \
               && wc_queue_row "${key%%:*}" "$kind" "$key" "$event" "$repo" "$id" || true
             continue ;;
    esac
    # <<< queue wakes (BH-4059)
    # THE HOOK IS ORG-WIDE ON PURPOSE (one hook, no per-repo bookkeeping to keep
    # in sync with fleet.conf), so deliveries for repos the fleet does not run
    # are the NORMAL case rather than an error. Named ONCE PER REPO PER DRAIN
    # instead of once per row: an org with a busy repo nobody here builds would
    # otherwise write the same line all day and bury the lines that matter.
    if ! project=$(repo_project "$repo"); then
      dropped_n=$((dropped_n+1))
      case " $dropped " in *" $repo "*) ;; *) dropped="$dropped $repo" ;; esac
      continue
    fi
    # AND IT MUST BE THIS BOX'S. The worker already filters by repo; this is the
    # second guard, so a mis-filtered row can never launch another box's lanes.
    # The exceptions are the hub's pr/checks rows for every repo, which feed
    # the fleet-wide conductor and the hub's own wake-class lanes, and its
    # lead-land rows for every repo, because only the hub lands (BH-4057).
    if ! owns "$project"; then
      case "$IS_HUB:$kind" in
        1:pr|1:checks|1:lead-land) ;;
        *) foreign_n=$((foreign_n+1))
           case " $foreign " in *" $repo "*) ;; *) foreign="$foreign $repo" ;; esac
           continue ;;
      esac
    fi
    case "$kind" in
      # Only the hub runs the conductor. Off the hub a pr/checks row still
      # reaches the wake classes below (pr-ci -> review-prs for this box).
      pr|checks) if [ "$IS_HUB" = 1 ]; then
                  want_conductor=1; pc_n=$((pc_n+1))
                  # The PR number, deduped, as owner/repo#n (BH-1387), with the
                  # repo lowercased as repo_project folds it (BH-1841). A key of
                  # '-', empty or not all digits names no PR and adds nothing,
                  # except a checks row's head sha (7-64 hex), which is looked
                  # up in pr-state.tsv after the loop (BH-3453).
                  lrepo=$(printf %s "$repo" | tr 'A-Z' 'a-z')
                  case "$key" in
                    ''|-|*[!0-9]*)
                      if [ "$kind" = checks ] && [ "$CONDUCTOR_KEYED" = 1 ] \
                         && [[ "$key" =~ ^[0-9a-fA-F]{7,64}$ ]]; then
                        sha_q+="$lrepo"$'\t'"${key,,}"$'\n'
                      fi ;;
                    *) case ",$conductor_prs," in
                         *",$lrepo#$key,"*) ;;
                         *) conductor_prs="${conductor_prs:+$conductor_prs,}$lrepo#$key" ;;
                       esac ;;
                  esac
                fi ;;
      push)      case " $push_projects "   in *" $project "*) ;; *) push_projects="$push_projects $project" ;; esac ;;
      deploy)    case " $deploy_projects " in *" $project "*) ;; *) deploy_projects="$deploy_projects $project" ;; esac ;;
      issue)     case " $issue_projects "  in *" $project "*) ;; *) issue_projects="$issue_projects $project" ;; esac
                # THE KEY IS THE POINT OF THE ROW. It goes into the pending list
                # the moment it is read, BEFORE any cooldown decision — a wake
                # the window holds back is a wake whose key the next launch
                # carries, which is what makes coalescing different from the
                # dropping this used to do.
                key_add "$project" "$key" ;;
      # The lead chain (BH-4057). A box reviews its own repos; the hub reviews
      # nothing and only marks the row so it can say so once. Only the hub
      # lands; a box handed a lead-land row does nothing with it.
      lead-review) if [ "$IS_HUB" = 1 ]; then want_lead_review=2; else want_lead_review=1; fi ;;
      lead-land)   [ "$IS_HUB" = 1 ] && want_lead_land=1 ;;
      # Recorded for the wake classes (BH-4058); no lane consumes them yet (#1034
      # follow-up) and cron still covers both. Acked like any row, never "unknown".
      deploy_failed|merge_group) ;;
      *)         say "wake $id: unknown kind '$kind' — dropped" ;;
    esac
    # Wake-classes row hook (BH-1034). Only for fleet rows; a failed class
    # call does not abort the existing dispatches or other classes.
    for __wl_class in "${WAKE_CLASSES[@]}"; do
      class_on "$__wl_class" || continue
      __wl_fn="wc_${__wl_class//-/_}_row"
      command -v "$__wl_fn" >/dev/null 2>&1 || continue
      "$__wl_fn" "$project" "$kind" "$key" "$event" "$repo" "$id" || true
    done
  done <<<"$rows"
  [ "$n" -gt 0 ] || { cursor_move "$scanned_top"; return 0; }
  [ "$dropped_n" -gt 0 ] && say "dropped $dropped_n wake(s): not a fleet repo —$dropped"
  [ "$foreign_n" -gt 0 ] && say "dropped $foreign_n wake(s): another box owns the repo —$foreign"

  # A CHECKS WAKE NAMES A HEAD, NOT A PR (BH-3453). ONE awk pass maps each
  # queued sha to its owner/repo#n through the conductor's pr-state.tsv (col 1
  # key, col 4 head): same repo, prefixes compared both ways with a 7-char floor
  # like mc_hb_blocks. A sha with no row (or every sha, when the file is
  # unreadable) is then looked up on GitHub, up to SHA_LOOKUPS per drain
  # (BH-5521, wck_sha_prs): an open PR with that head becomes a key. First, a
  # sha the conductor's pre-queue cache names as the MAIN of `pending` entries
  # becomes the keys of those PRs whose gate run completed (BH-8173,
  # wpk_done_prs, one runs read from the same budget). A sha still
  # unplaced launches nothing under WAKE_CONDUCTOR_FULL=0 (the sweep covers it)
  # and makes the launch unkeyed under 1, as before.
  if [ -n "$sha_q" ]; then
    local resolved r unres="" u_repo u_sha got k s_used=0 s_miss=0 s_unread=0 s_skip=0 s_pq=0 s_running=0 pq_rc
    if resolved=$(printf %s "$sha_q" | awk -F'\t' '
        NR==FNR { if (NF >= 2) { q++; qr[q]=$1; qs[q]=$2 } next }
        { k=tolower($1); h=tolower($4); rp=k; sub(/#[^#]*$/, "", rp)
          if (length(h) < 7) next
          for (i=1; i<=q; i++) if (qr[i]==rp) {
            s=qs[i]
            if (index(h, s)==1 || index(s, h)==1) { hit[i]=1; print k }
          } }
        END { for (i=1; i<=q; i++) if (!hit[i]) print "!\t" qr[i] "\t" qs[i] }' - "$H/state/merge-conductor/pr-state.tsv" 2>/dev/null); then
      while IFS= read -r r; do
        case "$r" in
          '') ;;
          '!'*) unres+="${r#!$'\t'}"$'\n' ;;
          *) case ",$conductor_prs," in *",$r,"*) ;; *) conductor_prs="${conductor_prs:+$conductor_prs,}$r" ;; esac ;;
        esac
      done <<<"$resolved"
    else
      unres="$sha_q"
    fi
    while IFS=$'\t' read -r u_repo u_sha; do
      [ -n "${u_sha:-}" ] || continue
      if [ "$SHA_LOOKUPS" -gt 0 ] && [ "$s_used" -lt "$SHA_LOOKUPS" ]; then
        # BH-8173: a main sha with PRs pending on it. rc 1 (nothing pending)
        # read nothing and falls through to wck_sha_prs; any other answer read
        # once and places the sha.
        if [ "$PREQUEUE_MAIN" = 1 ] && command -v wpk_done_prs >/dev/null 2>&1; then
          pq_rc=0
          got=$(wpk_done_prs "$H/state/merge-conductor" "$u_repo" "$u_sha" "$PREQUEUE_PAGE") || pq_rc=$?
          if [ "$pq_rc" != 1 ]; then
            s_used=$((s_used+1))
            case "$pq_rc" in
              0|2)
                s_pq=$((s_pq+1))
                for k in $got; do
                  case ",$conductor_prs," in *",$k,"*) ;; *) conductor_prs="${conductor_prs:+$conductor_prs,}$k" ;; esac
                done
                if [ "$pq_rc" = 0 ]; then
                  say "pr/checks: prequeue main ${u_sha:0:12} finished — woke $(printf '%s' "$got" | paste -sd, -)"
                else
                  say "pr/checks: prequeue main ${u_sha:0:12} run list unreadable — woke every PR pending on it: $(printf '%s' "$got" | paste -sd, -)"
                fi ;;
              *) s_running=$((s_running+1)) ;;
            esac
            continue
          fi
        fi
        if command -v wck_sha_prs >/dev/null 2>&1; then
          s_used=$((s_used+1))
          if got=$(wck_sha_prs "$u_repo" "$u_sha"); then
            for k in $got; do
              case ",$conductor_prs," in *",$k,"*) ;; *) conductor_prs="${conductor_prs:+$conductor_prs,}$k" ;; esac
            done
            continue
          elif [ "$?" = 1 ]; then s_miss=$((s_miss+1))
          else s_unread=$((s_unread+1)); fi
        else
          s_unread=$((s_unread+1))
        fi
      else
        s_skip=$((s_skip+1))
      fi
      [ "$CONDUCTOR_FULL" = 1 ] && conductor_all=1
    done <<<"$unres"
    if [ $((s_miss + s_unread + s_skip + s_running)) -gt 0 ]; then
      local tail_txt="not launched; the hourly sweep covers them"
      # A running pre-queue main never makes the launch unkeyed (BH-8173).
      [ "$CONDUCTOR_FULL" = 1 ] && [ $((s_miss + s_unread + s_skip)) -gt 0 ] && tail_txt="launched unkeyed"
      say "pr/checks: $((s_miss + s_unread + s_skip + s_running)) checks sha(s) named no open PR (lookups=$s_used miss=$s_miss unread=$s_unread skipped=$s_skip) prequeue=$s_pq running=$s_running — $tail_txt"
    fi
  fi

  # The conductor is FLEET-WIDE: it walks every repo in fleet.conf on every run,
  # so one launch answers every pr/checks wake in this batch whatever repo they
  # came from. Cooled under the literal project name "fleet" for that reason.
  # THE CAP IS CHECKED BEFORE THE COOLDOWN, not after it: `cooled` writes its
  # stamp on the same call that grants the launch, so asking it first would burn
  # the window on a launch that never happened and leave the NEXT invocation
  # braked for nothing. A held or refused launch is written to the owed marker
  # (state/wake-conductor-owed, BH-3453) before the wake is acked below, and a
  # later cycle pays it: cron/lanes/410-merge-conductor.cron fires only */30,
  # and the faster backstop lane is filed as #3454, not shipped. The held line
  # is one per invocation, written only when a pr/checks wake was actually held.
  if [ "$want_conductor" = 1 ]; then
    # BH-5521: no PR named, no run. The batch takes no cooldown and owes nothing;
    # the hourly sweep and the keyed backstop cover it. KEYED=0 is unchanged:
    # an unkeyed launch is that knob's meaning.
    if [ "$CONDUCTOR_FULL" = 0 ] && [ "$CONDUCTOR_KEYED" = 1 ] && [ -z "$conductor_prs" ]; then
      say "pr/checks: $pc_n wake(s) named no PR — no conductor run; the hourly sweep covers them"
    elif [ "$CONDUCTOR_CAP" != 0 ] && [ "$CONDUCTOR_LAUNCHED" -ge "$CONDUCTOR_CAP" ]; then
      if [ "$CONDUCTOR_HELD" = 0 ]; then
        say "pr/checks: conductor launch held — per-tick cap $CONDUCTOR_CAP reached (the cron sweep still covers it)"
        CONDUCTOR_HELD=1
      fi
      conductor_owe "$conductor_prs" "$conductor_all" cap
    else
      # A nearly-spent GitHub hour stretches the window rather than dropping the
      # launch, because the conductor re-reads every open PR anyway.
      if cooled pr fleet "$(conductor_window)"; then
        # One launch carries every woken key; with the knob off, no key to name,
        # or a sha that resolved to none, it is today's fleet-wide launch, argv
        # and label included.
        if [ "$CONDUCTOR_KEYED" = 1 ] && [ "$conductor_all" = 0 ] && [ -n "$conductor_prs" ]; then
          ( export MC_ONLY_PR="$conductor_prs"
            launch "pr/checks[$MC_ONLY_PR]" "$SELF/merge-conductor.sh" )
        else
          launch "pr/checks" "$SELF/merge-conductor.sh"
        fi
        CONDUCTOR_LAUNCHED=$((CONDUCTOR_LAUNCHED+1))
      else
        conductor_owe "$conductor_prs" "$conductor_all" cooldown
      fi
    fi
  fi
  local p PKEYS=""
  for p in $push_projects; do
    # deploy-train.sh departs on whatever bin/deploy-request.sh enqueued at the
    # merge; with an empty queue its own 20-minute self-source floor still
    # applies, and this loop does not reach past it. A push is permission to
    # ask the train to look, never permission to skip its own brake.
    cooled push "$p" && launch "push[$p]" "$SELF/deploy-train.sh" "$p"
  done
  for p in $deploy_projects; do
    cooled deploy "$p" && launch "deploy[$p]" "$SELF/postmerge-qa.sh" "$p"
  done
  for p in $issue_projects; do
    # NOT a triage launch — a one-shot file bin/triage-gate.sh consumes before
    # its 45-minute queue brake, so the next scheduled tick is not braked past a
    # client's answer. The gate stays the thing that decides to spend.
    touch "$H/state/wake-$p" 2>/dev/null && say "issue[$p]: triage gate un-braked for the next tick"
  done
  # The lead chain (BH-4057): one launch per drain and no cooldown, because
  # bin/lead-review.sh claims each request on the worker before it spends and
  # bin/lead-review-land.sh holds its own tick lock. fd 9 is this loop's lock,
  # closed so a long review never holds it.
  if [ "$want_lead_review$want_lead_land" != 00 ]; then
    if lane_switch lead-chain-wake-off file; then
      say "lead-chain doorbell off (flags/lead-chain-wake-off) — cron covers lead review/land"
    else
      [ "$want_lead_review" = 1 ] && ( exec 9>&-; launch "lead-review" "$SELF/lead-review.sh" tick )
      [ "$want_lead_review" = 2 ] && say "lead-review wake: the hub runs no lead review — dropped"
      [ "$want_lead_land" = 1 ] && ( exec 9>&-; launch "lead-land" "$SELF/lead-review-land.sh" )
    fi
  fi

  # ── THE TRIAGE LAUNCH (the operator, 2026-09-14) ──────────────────────────────────
  # AFTER the three loops above and never inside them: those launches are cheap
  # and unconditional, this one buys a session and has to see the whole batch
  # before it decides. An issue wake takes the cooldown ahead of a push wake for
  # the same project, because a client's answer is a stronger reason to spend
  # than a merge that may have released nothing.
  if [ ! -f "$LAUNCH_OFF" ]; then
    for p in $issue_projects; do
      if ! cooled triage "$p" "$TRIAGE_COOLDOWN"; then
        # NOT a drop. The keys are already in the pending list, so this says what
        # is true: the tick is being coalesced, and the next one past the window
        # carries everything held here. Before this the same situation was
        # silence, and silence is what an over-firing lane looks like too.
        say "triage[$p]: coalescing — $(key_pending "$p") key(s) held for the next launch (window ${TRIAGE_COOLDOWN}s)"
        continue
      fi
      # THE KEYS LEAVE THE PENDING LIST HERE, in the drain loop rather than in
      # the detached subshell below: this function is single-copy under the
      # loop's flock, a child of it is not, and two of them taking the list
      # would be the coalescing window losing a key.
      # shellcheck disable=SC2046  # the keys are [A-Za-z0-9._-] by key_add
      IKEYS=$(key_take "$p")
      # DETACHED, exactly like the push path and for the same reason: expanding
      # a closure is one gh lookup per key plus a dependency pass, and this
      # loop's job is to be back at the doorbell in fifteen seconds. An issue
      # that CLOSED carries the tickets it released into the scope; an issue
      # that was opened, edited or commented on expands to nothing and launches
      # exactly as it did before (bin/lib/revdep-lib.sh).
      # shellcheck disable=SC2046,SC2086  # keys are [A-Za-z0-9._-] by construction
      ( ( launch_triage "$p" "issue wake" $IKEYS \
            $(released_by "$p" issue $(issue_closures "$p" $IKEYS)) ) >/dev/null 2>&1 & ) 2>/dev/null
    done
    for p in $push_projects; do
      case " $issue_projects " in *" $p "*) continue ;; esac
      # The cooldown is taken BEFORE the children check, not after it: the gh
      # lookup is itself the thing being deduped, and a busy repo merging four
      # PRs in a minute must not buy four of them. The check then runs detached
      # for the same reason the launches do — the drain loop's job is to be back
      # at the doorbell in fifteen seconds, whatever GitHub is doing.
      cooled triage "$p" "$TRIAGE_COOLDOWN" || continue
      # ── THE COALESCED KEYS LEAVE THE LIST HERE TOO (BH-1130) ──────────────
      # The coalescing window is per PROJECT, and so is the one-shot un-brake —
      # but until this line only the ISSUE arm above ever emptied the pending
      # list. An issue wake held back by the window left its key there and its
      # un-brake written; this arm then took the very `triage` cooldown that key
      # was waiting out, and its launch SPENT that un-brake with a keys file
      # naming the push's children alone. bin/lib/rt/scope.sh scoped the tick it
      # bought to those children, so the held key was worked by neither the
      # fast path nor the tick and sat in the list until the next issue wake for
      # the same project — which on a quiet board may never come.
      # So the launch that consumes the un-brake carries what the window held.
      # Taken in the drain loop and never in the detached subshell below, for
      # the reason the issue arm states at its own key_take: this function is
      # single-copy under the loop's flock and a child of it is not. And only
      # AFTER `cooled` returned 0 — a push the window holds back (the `continue`
      # above) takes nothing, or the keys would be dropped on the floor by a
      # launch that never happened, which is this same orphan one arm over.
      PKEYS=$(key_take "$p") || PKEYS=""
      [ -n "$PKEYS" ] && say "push[$p]: $(grep -c . <<<"$PKEYS") coalesced key(s) fold into this tick"
      # A push row carries a head sha, which names no ticket. What the tick can
      # act on is the CHILDREN the merge released, and push_children has just
      # computed them — so they are the keys, together with whatever the window
      # held. Nothing else about the merge's aftermath belongs to triage (the
      # conductor and the deploy train own it), so a push tick that took the
      # whole board diff was buying sessions for tickets no merge had touched.
      # EITHER SIDE IS ENOUGH TO BUY THE LAUNCH, and that is the only thing rc
      # stopped deciding on its own: rc, not emptiness, is still the "did this
      # merge release a child" answer — push_children returns nonzero when it
      # found none, and kids it found but could not spell as keys still launch
      # keyless, exactly as before. A push that released nothing and is carrying
      # nothing still buys nothing. Kids first in the argv so a launch with an
      # empty pending list logs the line it logged yesterday.
      # shellcheck disable=SC2046,SC2086  # keys are [A-Za-z0-9._-] by construction
      ( ( KIDS=""; RELEASED=""; PKIDS=""
          KIDS=$(push_children "$p") && RELEASED=1
          # The folded keys get the SAME expansion the issue arm would have
          # given them (2026-09-15): a coalesced key that turns out to be a
          # CLOSE carries the tickets it released, one that was opened, edited
          # or commented on expands to nothing. Before launch_triage, because
          # both halves write state/wake-closed-<project> and the tick it
          # launches takes that file one-shot.
          [ -n "$PKEYS" ] && PKIDS=$(released_by "$p" push $(issue_closures "$p" $PKEYS))
          { [ -n "$RELEASED" ] || [ -n "$PKEYS" ]; } \
            && launch_triage "$p" "push wake${RELEASED:+, blocker closed}${PKEYS:+, coalesced issue key(s)}" \
                 $KIDS $PKEYS $PKIDS ) >/dev/null 2>&1 & ) 2>/dev/null
    done
  fi

  # Wake-classes dispatch hook (BH-1034). Once per non-empty drain, after the
  # existing launches and before the cursor moves/acks. A failed class call does
  # not abort the cursor, the ack, or other classes.
  for __wl_class in "${WAKE_CLASSES[@]}"; do
    class_on "$__wl_class" || continue
    __wl_fn="wc_${__wl_class//-/_}_dispatch"
    command -v "$__wl_fn" >/dev/null 2>&1 || continue
    "$__wl_fn" || true
  done

  # The watermark moves BEFORE the ack. Neither is the guard against a second
  # launch — the claim rows are — so a failed ack is housekeeping only.
  cursor_move "$scanned_top"
  wakes_ack "${ids[@]}" >/dev/null 2>&1 || say "ack failed for ${#ids[@]} wake(s) — the claim rows still dedupe"
  say "drained $n wake(s), scanned to id ${scanned_top:-?}"
}

i=0
while :; do
  hb_tick wake-loop "cycle $((i+1))"
  drain
  i=$((i+1))
  [ "$CYCLES" != 0 ] && [ "$i" -ge "$CYCLES" ] && break
  sleep "$INTERVAL"
done
hb_done wake-loop
exit 0
