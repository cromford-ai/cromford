#!/bin/bash
# SCALE-PLAN wave 2 — tech-lead decomposer. Invoked by run-build.sh when a plan
# sizes itself XL: fable splits the ticket into small, independently shippable
# children with NON-OVERLAPPING file scopes, files them on the same board, and
# narrates the split on the parent thread. Children then flow through the normal
# pipeline; the wave-1 conflict scheduler is what makes their parallelism safe.
# usage: run-decompose.sh <project> <ticket-id> <KEY> <build-dir> [max-lines] [max-files]
#
# max-lines/max-files (2026-09-12) are the per-CHILD budget, resolved by
# bin/size-threshold.sh and handed down by the size gate in run-build.sh. Before
# they existed the only instruction was "small (one build session)", which a
# model reads as whatever it likes — so a split could return children the size
# of the parent and buy a round trip and nothing else. OPTIONAL, with the same
# defaults the threshold helper uses, so a box running an older run-build.sh
# still splits; it just splits blind.
#
# GITHUB-ISSUES LANES SPLIT TOO (the operator, 2026-09-14). Until tonight the only way
# this script could file a child was an in-app board's ticket-create endpoint,
# so on a GitHub-Issues project (fleet.conf board prefix "-") it asked a model
# to POST to an API that project does not have. That is half the reason TK-552
# shipped 1,900 product lines across 18 files in one 33-minute execute and
# TK-556 was flagged decomposable the same night: both were built whole.
#
# THE ISSUES LANE IS DETERMINISTIC ON PURPOSE. The model writes a SPEC
# ($BUILD/children.json) and THIS SCRIPT files the issues, because the
# conventions the rest of the pipeline parses are exact and a model free-handing
# them breaks the ordering silently: the `ai-build` label IS the handoff
# (prompts/project-5.md), and `Blocked-by: #<n>` is the line
# bin/unblocked-children.sh reads to launch a child the moment its sibling
# closes. A child filed without the label is invisible; a child whose ordering
# line is phrased differently launches immediately and conflicts with the
# sibling it was supposed to follow.
#
# THE BOARD LANE IS DETERMINISTIC TOO (BH-3965). On an in-app board the model
# writes the same children.json, the same checks refuse a bad one, and
# file_children hands it to bin/lib/fc-board.sh, which knows the keys and ids
# its create calls returned: `parentId` + `dependsOn` on a board that
# advertises "dependencies", `Blocked-by: <board key> (hard)` text on one that
# does not. The switch `decompose-board-filer-off` (lane_switch, file mode: the
# settings row, then flags/) puts back the model-filed path, the BH-866 label
# re-map and the parking tail below the spec block, unchanged.
#
# TRACER FIRST (BH-3954, the operator, 2026-10-03). The first child is the TRACER: the
# thinnest end-to-end path, from a real trigger to a persisted result to an
# outcome someone can observe, filed as `<KEY>.0: contract — <slice>` with a
# `CONTRACT:` line naming the names and paths it really lands (working code the
# siblings import, not stubs) and targeted at 60 product lines rather than the
# per-child budget. A stub contract proved nothing until the last sibling
# landed, so wrong assumptions surfaced after the whole wave was built on them.
# Siblings each add one user capability end to end, never one layer: a "UI
# child" / "API child" split is a decomposition failure, like a chain. Every
# child body carries a `## Observable outcome` section, and a spec where any
# child has none is refused as DECOMPOSE_FAILED before anything is filed.
#
# THE PARALLEL WAVE (BH-481, the operator, 2026-09-16). Every sibling carries
# `Blocked-by: #<.0> (hard)` and
# nothing else unless the spec declares an import from a sibling, which is then a
# hard blocker too, so the split is a parallel wave on top of one small chunk
# instead of a chain. Two things were wrong with chains: 30 of one project's 46 open
# children arrived as 3-5 level `Blocked-by` chains at ~50 minutes a level, and
# the parents carrying them were big enough to collide with main and be rebuilt
# (9 of 31 merged PRs in one night were r2+, 40-90 commits behind), which strands
# every child behind them. A 20-line first chunk almost never conflicts. The
# siblings do not wait for it to MERGE either: stacked builds (STACK_BASE) put
# them on its branch the minute its PR opens, which is the expected path. More
# than 2 chain levels beyond the contract is refused as DECOMPOSE_FAILED, because
# a third level is a decomposition failure and not a dependency.
#
# DECOMPOSE_DRY_RUN=1 prints every gh command instead of running it, and reuses
# an existing children.json instead of buying a Fable call. That is how
# tests/run-decompose-issues-test.sh checks the exact issue bodies with no
# network and no model, and it is also the honest way to inspect a real split
# before it touches a client's repo.
#
# THE PARENT IS PARKED, per lane convention: `in_progress` on a board, and on an
# issues lane the `ai-build` label comes OFF — the label is the handoff, so an
# unlabelled issue is a master no watcher re-claims. The issue stays OPEN and
# tracks its children (TK-138/171/119/128, 2026-08-12, are the board-side
# version of the same lesson).
#
# COST (2026-09-14): one Fable call, written to the ledger as `stage=decompose`.
# It rode as `stage=plan` until tonight, which put the price of a split inside
# planning and made "what has decomposition cost us" unanswerable. The runner
# and its failover are inherited from the plan stage so the routing a box has
# configured does not change on the day the stage gets its own name.
set -uo pipefail
PROJECT="${1:?project}"; TICKET="${2:?ticket id}"; KEY="${3:?key}"; BUILD="${4:?build dir}"
MAXL="${5:-700}"; MAXF="${6:-20}"
case "$MAXL" in ''|*[!0-9]*) MAXL=700 ;; esac
case "$MAXF" in ''|*[!0-9]*) MAXF=20 ;; esac
# THE CONTRACT CHILD'S OWN BUDGET (BH-481, 2026-09-16). It is not the per-child
# budget above and must not be: every sibling is blocked on this one chunk, so
# what it costs is paid by the whole wave, and a chunk this size almost never
# collides with the default branch — which is the other half of the point, since
# a parent that gets rebuilt strands every child hanging off it.
CONTRACT_MAXL="${CONTRACT_MAX_LINES:-60}"
case "$CONTRACT_MAXL" in ''|*[!0-9]*) CONTRACT_MAXL=60 ;; esac
# Overridable so this can be DRIVEN against a scratch tree, the same words
# run-build.sh uses for the same reason. Cron and the fly runner set neither, so
# production resolves to exactly the path it always has.
HARNESS="${HARNESS:-/root/harness}"
. "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$HARNESS")
set -a; . "$HENV/global.env" 2>/dev/null; [ -f "$HENV/$PROJECT.env" ] && . "$HENV/$PROJECT.env"; set +a
# THE TOKEN gh USES IS READ AT CALL TIME (2026-09-15, TK-855/880/881/882/921).
# On a pool machine GH_TOKEN is a GitHub App installation token that dies in an
# hour, and warm machines outlive it: run-build.sh already re-reads the live
# token (bin/lib/gh-token-live.sh) before every push and `gh pr create`, but this
# script inherited the minute-0 token, so `gh issue create` on child 1 answered
# "Try authenticating with: gh auth login" and five XL tickets were parked
# DECOMPOSE_FAILED "held for a human" — which nothing in this harness may be.
# rc-safe on the hub and boxes (no live file there): the environment is untouched.
# shellcheck source=bin/lib/gh-token-live.sh
[ -r "$HARNESS/bin/lib/gh-token-live.sh" ] && . "$HARNESS/bin/lib/gh-token-live.sh"
gh_fresh() { if command -v gh_token_live >/dev/null 2>&1; then gh_token_live || true; fi; return 0; }
gh_fresh
STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
LOG() { echo "$(STAMP) [$PROJECT/$KEY] $*" >> "$BUILD/pipeline.log"; }
# Single-quoted, so a printed command is both paste-safe and readable — `printf
# %q` turns an ordinary issue title into backslash soup nobody can check by eye.
SQ() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
case "$(printf '%s' "${DECOMPOSE_DRY_RUN:-0}" | tr '[:upper:]' '[:lower:]')" in
  1|true|yes|on) DRY=1 ;;
  *)             DRY=0 ;;
esac
# THE CHILD FILER IS A LIBRARY (BH-982). Both lanes below need it: the issues
# lane files its children through file_children, and the board tail reads that
# board's own API base and prefix through fc_board_base instead of the one board
# path this script used to hardcode. Sourced here, above the lane switch,
# because both need it; sourcing is inert (no set -e, no exit, nothing written).
# shellcheck source=bin/lib/file-children.sh
if [ -r "$(dirname "$0")/lib/file-children.sh" ]; then . "$(dirname "$0")/lib/file-children.sh"
elif [ -r "$HARNESS/bin/lib/file-children.sh" ]; then . "$HARNESS/bin/lib/file-children.sh"
fi
# The board token resolver (BH-1955), same two rungs; also inert on source.
# shellcheck source=bin/lib/board-creds.sh
if [ -r "$(dirname "$0")/lib/board-creds.sh" ]; then . "$(dirname "$0")/lib/board-creds.sh"
elif [ -r "$HARNESS/bin/lib/board-creds.sh" ]; then . "$HARNESS/bin/lib/board-creds.sh"
fi
# The untrusted-input rule (BH-4491): both prompts below have the agent read
# the parent's thread itself, so they open with it. No lib = today's prompts.
# shellcheck source=bin/lib/untrusted-input.sh
if [ -r "$(dirname "$0")/lib/untrusted-input.sh" ]; then . "$(dirname "$0")/lib/untrusted-input.sh"
elif [ -r "$HARNESS/bin/lib/untrusted-input.sh" ]; then . "$HARNESS/bin/lib/untrusted-input.sh"
fi
DEC_UI_NOTICE=""
command -v ui_notice >/dev/null 2>&1 && DEC_UI_NOTICE="$(ui_notice)"$'\n\n'
# The kill-switch reader (BH-2320), same two rungs; with neither it is the flag
# file alone.
# shellcheck source=bin/lib/lane-switch.sh
command -v lane_switch >/dev/null 2>&1 || . "$(dirname "$0")/lib/lane-switch.sh" 2>/dev/null \
  || . "$HARNESS/bin/lib/lane-switch.sh" 2>/dev/null || lane_switch() { [ -f "$HARNESS/flags/$1" ]; }
# >>> context packs (BH-3478)
# Each filed child gets its parent planner's map (bin/lib/context-pack-compose.sh),
# written to $BUILD/context-packs/<CHILD>.md and published with cp_put
# (bin/lib/context-pack.sh) so the child's plan starts warm. An optimisation,
# never a gate: one pipeline.log line per child, no page, no exit, and the
# script's rc is whatever it was going to be. Both libs load in the same two
# rungs as above; a missing one is a log line, not a failure.
# shellcheck source=bin/lib/context-pack-compose.sh
if [ -r "$(dirname "$0")/lib/context-pack-compose.sh" ]; then . "$(dirname "$0")/lib/context-pack-compose.sh"
elif [ -r "$HARNESS/bin/lib/context-pack-compose.sh" ]; then . "$HARNESS/bin/lib/context-pack-compose.sh"
fi
# shellcheck source=bin/lib/context-pack.sh
if [ -r "$(dirname "$0")/lib/context-pack.sh" ]; then . "$(dirname "$0")/lib/context-pack.sh"
elif [ -r "$HARNESS/bin/lib/context-pack.sh" ]; then . "$HARNESS/bin/lib/context-pack.sh"
fi
# dcp_publish <spec-or-empty> — always rc 0. Line n of children.txt is spec
# index n-1 (bin/lib/fc-issues.sh, bin/lib/fc-board.sh), so each lane that files
# from the spec gives each child its own body and never a sibling's; only the
# legacy model-filed board path passes "" and the pack says to read the
# thread. The loop reads fd 3 and cp_put gets /dev/null, so nothing it runs can
# eat the rest of children.txt.
dcp_publish() {
  local spec="${1:-}" pf="$BUILD/planned-files.txt" dir="$BUILD/context-packs"
  local sha total n=0 child body rc word
  [ -s "$BUILD/children.txt" ] || return 0
  total=$(grep -c . "$BUILD/children.txt")
  [ -f "$pf" ] || "$(dirname "$0")/planned-files.sh" "$BUILD" >/dev/null 2>&1 || true
  mkdir -p "$dir" 2>/dev/null || return 0
  sha=$(git rev-parse --verify -q HEAD 2>/dev/null) || sha=""
  while IFS= read -r child <&3 || [ -n "$child" ]; do
    n=$((n + 1))
    [ -n "$child" ] || continue
    case "$child" in *[!A-Za-z0-9._-]*) LOG "context pack not composed (bad child key) for $child"; continue ;; esac
    [ "$child" != "$KEY" ] || { LOG "context pack not composed (bad child key) for $child"; continue; }
    body=""
    if [ -n "$spec" ]; then
      body="$dir/.body"
      jq -r --argjson i "$((n - 1))" '.[$i].body // empty' "$spec" > "$body" 2>/dev/null
      [ -s "$body" ] || { LOG "context pack not composed (no spec entry $n) for $child"; continue; }
    fi
    command -v cp_compose >/dev/null 2>&1 \
      || { LOG "context pack not composed (compose lib missing) for $child"; continue; }
    cp_compose "$BUILD/plan.md" "$pf" "$body" "$child" "$KEY" "$n" "$total" > "$dir/$child.md.tmp" 2>/dev/null; rc=$?
    if [ "$rc" -ne 0 ]; then
      rm -f "$dir/$child.md.tmp"
      if [ "$rc" -eq 3 ]; then LOG "context pack not composed (over the pack cap) for $child"
      else LOG "context pack not composed (compose rc=$rc) for $child"; fi
      continue
    fi
    mv -f "$dir/$child.md.tmp" "$dir/$child.md" \
      || { LOG "context pack not composed (write failed) for $child"; continue; }
    if [ "$DRY" = 1 ]; then
      echo "would POST /api/context-packs $child"
      LOG "context pack dry-run for $child"
      continue
    fi
    command -v cp_put >/dev/null 2>&1 \
      || { LOG "context pack unreachable (context-pack.sh missing) for $child"; continue; }
    JOBS_ALERT=0 cp_put "$PROJECT" "$child" "$KEY" "$sha" "$dir/$child.md" >/dev/null 2>&1 </dev/null; rc=$?
    case "$rc" in 0) word=published ;; 3) word=REFUSED ;; *) word=unreachable ;; esac
    LOG "context pack $word for $child"
  done 3< "$BUILD/children.txt"
  rm -f "$dir/.body"
  return 0
}
# <<< context packs
# >>> enqueue children (BH-3970)
# A CHILD THIS SCRIPT FILED IS ENQUEUED BY THIS SCRIPT. Before this block the
# board lane filed, re-mapped and parked, and left the children for triage to
# discover. On project-8 (2026-10-03) triage never did: the board's
# own `[AI Triage]` note read as our write, the client-court guard skipped all
# 32 children, the fingerprint was consumed, and nothing re-offered them until
# a human ran `jobs-client.sh ready-put` by hand.
#
# So every child gets a ready row and, on the box that owns the project, a
# READY-QUEUE.log line plus flags/force-triage-<p>: the same two halves
# bin/stale-owed-tickets.sh writes (`# >>> ready rows`). children.txt order IS
# landing order (the prompt makes child 1 the contract), so the rows go in that
# order. Sibling dependency gating is #3946, not this block; a board that
# serves `blocked:true` already defers siblings at the buildable gate.
#
# A SUBSHELL, because bin/jobs-client.sh may `exit` on a broken install and
# the parent still has to be parked below. Idempotent on a re-run: the worker
# answers `duplicate` per project+key, and the file line is key-guarded.
#
# BOTH BOARD PATHS CALL IT (BH-3965). The legacy model-filed path calls it after
# the BH-866 re-map; the harness-filed default calls it after file_children,
# whose children-board.tsv (`<n>\t<key>\t<id as JSON>`) carries each child's
# board id, so that path needs no board read either.
dcp_enqueue_children() {
  if [ "$DRY" != 1 ]; then
    (
      for _RQ in "$(dirname "$0")/lib/ready-queue.sh" "$HARNESS/bin/lib/ready-queue.sh"; do
        # shellcheck source=bin/lib/ready-queue.sh
        [ -r "$_RQ" ] && { . "$_RQ"; break; }
      done
      # The ticket ids come from the re-map's board list when it read one. A
      # split that needed no re-map costs no board read (run-decompose-board-
      # keys pins that), so its rows carry `-`: rq_lines synthesizes the line,
      # and the shards guard resolves the id from the keymap the next tick builds.
      # The file half belongs to the box that owns the project: bin/box-for.sh
      # answers `local` on the hub and the box's fleet name elsewhere.
      _OWNER=$("$HARNESS/bin/box-for.sh" "$PROJECT" 2>/dev/null || echo local)
      _ME=$("$HARNESS/bin/box-name.sh" 2>/dev/null || true)
      _LOCAL=0
      if [ "$_OWNER" = local ] || [ -z "$_OWNER" ] || { [ -n "$_ME" ] && [ "$_OWNER" = "$_ME" ]; }; then _LOCAL=1; fi
      _ROWS=0; command -v rq_on >/dev/null 2>&1 && rq_on && _ROWS=1
      _RQF="$HARNESS/logs/READY-QUEUE.log"
      _TOTAL=$(grep -c . "$BUILD/children.txt"); _I=0; _OK=""; _NOROW=""; _NEWF=0
      while IFS= read -r _K; do
        [ -n "$_K" ] || continue
        _I=$((_I + 1))
        _TID=$(jq -r --arg k "$_K" --arg pfx "${KEY%%-*}" '
          def tkey: (.key // (if (.number // null) != null and ($pfx != "")
                              then ($pfx + "-" + ((.number|tostring))) else "" end));
          ( if type == "array" then . else (.tickets // .data.tickets // []) end )
          | map(select(tkey == $k)) | (.[0].id // "") | tostring' <<<"${BOARD_TICKETS:-}" 2>/dev/null) || _TID=""
        # The harness filer recorded the id it was handed for this key.
        [ -n "$_TID" ] || _TID=$(awk -F'\t' -v k="$_K" '$2 == k { print $3; exit }' \
          "$BUILD/children-board.tsv" 2>/dev/null | jq -r 'tostring' 2>/dev/null) || _TID=""
        [ -n "$_TID" ] || _TID="-"
        _LINE="$_K $_TID — decompose child $_I of $_TOTAL of $KEY project=$PROJECT"
        if [ "$_ROWS" = 1 ]; then
          if queue_ready_put "$PROJECT" "$_K" "$_TID" "$_LINE" >/dev/null 2>&1; then :; else _NOROW="$_NOROW,$_K"; fi
        fi
        if [ "$_LOCAL" = 1 ] && ! grep -qE "^${_K}[[:space:]]" "$_RQF" 2>/dev/null; then
          mkdir -p "$HARNESS/logs" && printf '%s\n' "$_LINE" >> "$_RQF" && _NEWF=1
        fi
        _OK="$_OK,$_K"
      done < "$BUILD/children.txt"
      [ "$_NEWF" = 1 ] && mkdir -p "$HARNESS/flags" && touch "$HARNESS/flags/force-triage-$PROJECT"
      _HOW="ready rows $([ "$_ROWS" = 1 ] && echo on || echo off), READY-QUEUE.log $([ "$_LOCAL" = 1 ] && echo "on this box" || echo "not this box's ($_OWNER)")"
      if [ "$_ROWS" = 0 ] && [ "$_LOCAL" = 0 ]; then
        LOG "WARN: enqueued NOTHING fleet-visibly for ${_OK#,} — $_HOW; the starved-ready alarm pages if nothing picks them up"
      elif [ -n "$_NOROW" ] && [ "$_LOCAL" = 0 ]; then
        LOG "WARN: enqueued children ready: ${_OK#,} — but ${_NOROW#,} got no ready row and has no READY-QUEUE.log line here ($_HOW)"
      else
        LOG "enqueued $_I children ready: ${_OK#,} ($_HOW${_NOROW:+; no row for ${_NOROW#,}, the file line carries it})"
      fi
    ) || LOG "WARN: the child enqueue stopped early (rc=$?) — the starved-ready alarm pages if nothing picks them up"
  fi
}
# <<< enqueue children
# Inherited, not re-decided: the ledger stage is renamed, the routing is not.
export RUNNER_DECOMPOSE="${RUNNER_DECOMPOSE:-${RUNNER_PLAN:-claude}}"
export RUNNER_DECOMPOSE_FALLBACK="${RUNNER_DECOMPOSE_FALLBACK:-${RUNNER_PLAN_FALLBACK:-}}"

# WHICH LANE. A fleet.conf board prefix of "-" is the GitHub-Issues lane, the
# same test bin/unblocked-children.sh and bin/triage-gate.sh apply; anything
# else is an in-app product board, filed by bin/lib/fc-board.sh (BH-3965).
BOARD_PREFIX=$("$HARNESS/bin/fleet-conf.sh" "$PROJECT" board_prefix 2>/dev/null || true)
GH_REPO="${GH_ISSUES_REPO:-}"
[ -n "$GH_REPO" ] || GH_REPO=$("$HARNESS/bin/fleet-conf.sh" "$PROJECT" repo 2>/dev/null || true)
case "$TICKET" in
  ''|*[!0-9]*) ISSUE=$(sed -nE 's/^[A-Za-z]+-([0-9]+)$/\1/p' <<<"$KEY") ;;
  *)           ISSUE="$TICKET" ;;
esac
LANE=board
[ "$BOARD_PREFIX" = "-" ] && LANE=issues
# THE BOARD LANE FILES FROM A SPEC TOO (BH-3965) unless this switch is on.
FILER_OFF=0
[ "$LANE" = board ] && lane_switch decompose-board-filer-off file && FILER_OFF=1

# >>> model-route (BH-1510.2): model_routes role `decompose`. No route = rc 75
# before anything is filed or bought, with the reason in decompose-run.txt (the
# file bin/run-build.sh's DECOMPOSE_FAILED result points at); the role itself is
# alerted by bin/lib/model-route.sh. Nothing is guessed.
. "$HARNESS/bin/lib/lane-model.sh"
DECOMPOSE_M=$(lane_role_model decompose "$PROJECT") || {
  echo "DECOMPOSE_FAILED: no model route for role decompose" > "$BUILD/decompose-run.txt"
  echo "$(STAMP) [$PROJECT/$KEY] DECOMPOSE not started: no model route for role decompose" >> "$BUILD/pipeline.log"; exit 75; }
# <<< model-route
echo "$(STAMP) [$PROJECT/$KEY] DECOMPOSE ($DECOMPOSE_M)" >> "$BUILD/pipeline.log"
[ "$FILER_OFF" = 1 ] && LOG "decompose-board-filer-off is on: the model files the children (pre-BH-3965 path)"

if [ "$LANE" = issues ] || [ "$FILER_OFF" = 0 ]; then
  # ------------------------------------------- issues lane, and the board's spec
  [ "$DRY" = 1 ] && DRYNOTE=" (DRY RUN, nothing is written)" || DRYNOTE=""
  if [ "$LANE" = issues ]; then
    LOG "decompose lane: GitHub issues (${GH_REPO:-no repo}, parent #${ISSUE:-?})$DRYNOTE"
  else
    LOG "decompose lane: board, filed by the harness (parent $TICKET)$DRYNOTE"
  fi
  # The reason lands in BOTH places on purpose: pipeline.log is where a build is
  # read, and decompose-run.txt is the artifact the sweep SOP names in its one
  # ALERTS line for DECOMPOSE_FAILED — an alert pointing at a file that does not
  # explain itself is an alert nobody can act on.
  FAIL() {
    LOG "decompose FAILED ($LANE lane): $1"
    echo "DECOMPOSE_FAILED: $1" >> "$BUILD/decompose-run.txt"
    exit 1
  }
  if [ "$LANE" = issues ]; then
    [ -n "$GH_REPO" ] || FAIL "no GitHub repo for this project in fleet.conf"
    [ -n "$ISSUE" ] || FAIL "cannot derive an issue number from ticket '$TICKET' / key '$KEY'"
    # A HELD TICKET IS NEVER SPLIT (BH-1526). BH-1485 was cut into five children
    # minutes after it was filed while the lead built the parent on the Mac. The
    # reading is bin/lib/hold.sh's through bin/lib/ticket-ownership.sh; rc 3 is
    # the caller's deferral (bin/run-build.sh), never a DECOMPOSE_FAILED page. A
    # read that did not answer splits as today.
    # shellcheck source=bin/lib/ticket-ownership.sh
    if [ -r "$(dirname "$0")/lib/ticket-ownership.sh" ]; then . "$(dirname "$0")/lib/ticket-ownership.sh"
    elif [ -r "$HARNESS/bin/lib/ticket-ownership.sh" ]; then . "$HARNESS/bin/lib/ticket-ownership.sh"
    fi
    if command -v to_build_hold >/dev/null 2>&1 && DEC_HOLD=$(to_build_hold "$PROJECT" "$ISSUE" "$KEY"); then
      LOG "decompose REFUSED: #$ISSUE is held (${DEC_HOLD#*	}) — a held ticket is never split"
      echo "DECOMPOSE_HELD: #$ISSUE is held (${DEC_HOLD#*	})" >> "$BUILD/decompose-run.txt"
      exit 3
    fi
  fi
  command -v jq >/dev/null 2>&1 || FAIL "jq is not on this box"
  [ "$LANE" != issues ] || [ "$DRY" = 1 ] || command -v gh >/dev/null 2>&1 || FAIL "gh is not on this box"
  # The three phrases of the spec prompt that name the lane. The issues values
  # are the text this prompt has always carried.
  if [ "$LANE" = issues ]; then
    DCP_SUBJECT="Ticket $KEY (GitHub issue #$ISSUE in $GH_REPO)"
    DCP_READ="Read the issue's FULL thread (\`gh issue view $ISSUE -R $GH_REPO --json title,body,comments,labels,state\`), the project's board rules in /root/harness/prompts/$PROJECT.md, and the oversized plan at $BUILD/plan.md."
    DCP_NOFILE="Do not create an issue, do not comment, do not touch a label, do not change any code. This harness files the children itself, because the ordering and handoff lines it writes ('Part of', 'Order:', 'Blocked-by:', 'CONTRACT:', 'DEPENDS:', 'Owns:', the ai-build label) have to be exact for the launcher to parse them."
  else
    DCP_SUBJECT="Ticket $KEY (id $TICKET)"
    DCP_READ="Read the ticket's FULL thread (board access method + endpoints in /root/harness/prompts/$PROJECT.md) and the oversized plan at $BUILD/plan.md."
    DCP_NOFILE="Do not create a ticket, do not comment, do not move the ticket's status, do not change any code. This harness files the children itself, because the ordering and handoff lines it writes ('Part of', 'Order:', 'Blocked-by:', 'CONTRACT:', 'DEPENDS:', 'Owns:') and the board's dependency fields have to be exact for the launcher to parse them."
  fi

  SPEC="$BUILD/children.json"
  PROMPT="$DEC_UI_NOTICE""You are the tech lead for this project. $DCP_SUBJECT is too large for one build session — its plan is over this project's decomposition threshold of $MAXL lines of product code / $MAXF files, or it sized itself XL. Your job: SPLIT it, do not build it.

$DCP_READ

TRACER FIRST. Before you slice anything, answer one question: what is the thinnest END-TO-END path through this feature? A real trigger (a user action, a cron tick, a webhook), then a persisted result, then an observable outcome (a preview screen, an API response, or for work with no UI a real row or log line). THAT IS CHILD 1, THE TRACER, and it is small on purpose: aim for $CONTRACT_MAXL lines of product code or fewer. Its contract names the exported names and paths the tracer really uses, so the siblings import WORKING code. Stubs that do nothing are not a tracer: the point is that a wrong assumption shows up on child 1, not after every sibling is built on it. It lands first and every other child is a parallel wave on top of it. A first chunk that size almost never conflicts with the default branch, so the children hanging off it almost never strand behind a rebuilt parent, and they all build at the same time instead of queueing behind each other.

SHARED SEAMS GO IN THE CONTRACT. Before you finalize the siblings, list every file two or more siblings would both edit: a registry or index they each add a row to, a prompt or doc each adds a section to, a module each adds a function to. The contract creates those seams so each sibling then edits ONLY its own: a fragment file or registry slot per sibling (a new file each sibling owns, never a shared list each appends to), a headed section stub per sibling in the shared prompt or doc, an empty module file per sibling. These seams are the one place a contract may land empty files, because they exist so siblings never touch the same lines. Name every seam path in the contract field.

ONE SEAM FILE PER LATER CHILD. The contract creates one seam file for each later child: an empty placeholder export that the shared code already imports, with a one-line comment that names the owner as '$KEY.<n>'. Each later child edits only its own seam file(s) and files no other sibling lists. A shared list is a registry folder with one file per entry, never an array that several children append to. If two children must edit the same existing file, the later one names the earlier in 'after' as \"<position>: same file <path>\". That makes it a hard blocker, so use it only when no seam is possible.

Siblings do NOT wait for the contract to merge. The moment the contract's pull request is open this harness builds them on its branch (STACK_BASE, docs/BUILD-CONCURRENCY.md), and GitHub retargets their pull requests when the contract merges. So blocking every sibling on the contract costs minutes, not a chain level, and it is the expected path.

Then design the siblings, 1 to 4 of them. Each sibling adds ONE CAPABILITY END TO END (for example list, create, edit, export) and touches whatever layers that capability needs. Each one MUST be: UNDER THE BUDGET (at most $MAXL lines of product code across at most $MAXF files — count source only, not tests, docs, the plan, lockfiles or generated code; if a slice cannot fit, slice it again rather than declaring an exception), independently shippable (the app works after the contract and that one child merge), and file-disjoint from every other sibling (list each child's intended files/dirs explicitly in its body). A sibling imports THE TRACER, not another sibling: if two siblings need the same symbol or file, it belongs in the tracer, so move it there rather than chaining them. Declaring an import from a sibling is allowed and it is honest, but it costs that child its place in the wave, because the filer blocks it on that sibling too.

CHAINS ARE A DECOMPOSITION FAILURE, NOT A DEPENDENCY. At most 2 levels beyond the contract, and a spec that declares more is refused outright and this ticket comes back unsplit.

A LAYER SPLIT IS A DECOMPOSITION FAILURE, the same as a chain: a 'UI child', 'API child', 'worker child' or 'schema child' builds pieces nobody can observe until the last one lands. Slice by what a user can do, not by where the code lives.

YOU DO NOT FILE ANYTHING. $DCP_NOFILE Your ONLY output is a spec file.

Write $SPEC — a JSON array, 2 to 5 objects, THE TRACER FIRST and then the siblings, no prose around it and no code fence:
[
  {\"title\": \"scan tracer\", \"contract\": \"src/api/scan.ts: GET /scan; src/lib/scan/store.ts: readScan(), writeScan()\", \"owns\": [\"src/api/scan.ts\", \"src/lib/scan/store.ts\", \"src/lib/scan/list.ts\", \"src/lib/scan/export.ts\"], \"after\": [], \"body\": \"markdown for the child issue\\n\\n## Observable outcome\\nPOST a scan, then GET /scan returns it\"},
  {\"title\": \"scan list\", \"owns\": [\"src/lib/scan/list.ts\", \"src/app/scans/page.tsx\"], \"after\": [], \"body\": \"...\\n\\n## Observable outcome\\nthe /scans page lists the stored scans\"},
  {\"title\": \"scan export\", \"owns\": [\"src/lib/scan/export.ts\", \"src/api/scan-export.ts\"], \"after\": [\"2: listScans()\"], \"body\": \"...\\n\\n## Observable outcome\\nGET /scan/export returns a CSV of them\"}
]
  contract — ON THE FIRST OBJECT ONLY, and REQUIRED: the exported names and the paths the tracer really lands, the working code the siblings import, and every shared seam it pre-creates (path: what it is for). The filer turns it into the child's 'CONTRACT:' line and titles that child '$KEY.0: contract — <slice name>'. No contract, no split: the spec is refused.
  title — the slice, a few words. Do NOT prefix it with a key; the filer writes '$KEY.<n>: ' itself.
  after — LAST RESORT, and it is the thing to design away: the 1-based positions IN THIS ARRAY WHOSE CODE THIS CHILD IMPORTS, written as \"<position>: <the symbol>\" so the reason is on the record. Position 1 is the contract and is never listed — the filer blocks every sibling on it. Naming a sibling here is not a hint: the filer makes that sibling a HARD BLOCKER on the same line, so this child waits for it (or stacks on its branch) exactly as it waits for the contract. Prefer [] and prefer moving the shared symbol into the contract: file-disjoint children that build at the same time are the entire point of the split, and an over-declared 'after' is a child that sits idle for an hour it did not owe. An ordering PREFERENCE is not a dependency. Never name a position at or after this child's own.
  owns — the repo paths this child creates or edits, as a JSON array of strings: its seam file(s) plus files no sibling lists. The filer writes them as the child's 'Owns:' line. Two children never own the same path unless the later one names the earlier in 'after'.
  imports_contract — siblings only, optional, default true. Write false ONLY when this slice uses no name on the contract's CONTRACT: line and edits no file the contract lands. Such a sibling is filed with no blocker and builds on main in parallel with the contract. If you are not sure, leave it out.
  body  — everything a builder needs and nothing it does not: the exact scope, the intended file list, the acceptance tests this slice owns from the parent plan, and any context from the thread. EVERY body, the tracer's included, carries a '## Observable outcome' section: the one acceptance test that exercises that child's path end to end, or for KIND infra/migration the real row or log line it produces, plus the QA screens when there is UI. A child with no Observable outcome section is refused and the ticket comes back unsplit. Do NOT write 'Part of', 'Order:', 'Blocked-by:', 'CONTRACT:', 'DEPENDS:', 'Owns:' or a size budget line — the filer appends those.

Final output line: exactly 'DECOMPOSE_SPEC_READY' or 'DECOMPOSE_FAILED: <reason>'."

  if [ -s "$SPEC" ]; then
    LOG "reusing the children.json already in the build dir, no Fable call"
  else
    "$HARNESS/bin/agent-call.sh" decompose "$PROJECT" "$DECOMPOSE_M" 2400 "$BUILD/decompose-run.txt" "$PROMPT" >/dev/null 2>&1
    RC=$?
    [ -s "$SPEC" ] || FAIL "rc=$RC, no children.json (see $BUILD/decompose-run.txt)"
  fi

  # A fenced answer is a formatting slip, not a failed split — strip the fence
  # and re-read before giving up on a spec that is sitting right there.
  if ! jq -e 'type == "array"' "$SPEC" >/dev/null 2>&1; then
    sed -e '/^[[:space:]]*```/d' "$SPEC" > "$SPEC.unfenced" 2>/dev/null
    if jq -e 'type == "array"' "$SPEC.unfenced" >/dev/null 2>&1; then
      mv "$SPEC.unfenced" "$SPEC"; LOG "children.json was fenced — unfenced it"
    else
      rm -f "$SPEC.unfenced"
    fi
  fi
  N=$(jq 'length' "$SPEC" 2>/dev/null)
  case "${N:-}" in ''|*[!0-9]*) FAIL "children.json is not a JSON array (see $SPEC)" ;; esac
  # 2-5 is the contract in the prompt. One child is not a split, and past five
  # the coordination cost is worse than the review cost being avoided.
  { [ "$N" -ge 2 ] && [ "$N" -le 5 ]; } || FAIL "a split is 2-5 children, the spec has $N"
  jq -e 'all(.[]; ((.title? // "") | length) > 0 and ((.body? // "") | length) > 0)' "$SPEC" >/dev/null 2>&1 \
    || FAIL "every child needs a non-empty title and body"

  # ---- INTERFACE FIRST: the contract child, and the chain cap (BH-481) -----
  # 30 of one project's 46 open children arrived as 3-5 level `Blocked-by`
  # chains, and at ~50 minutes a level that is hours of a pool that is otherwise
  # idle. The second half is worse: a parent big enough to collide with main gets
  # rebuilt (9 of 31 merged PRs in one night were r2+, 40-90 commits behind), and
  # every child chained behind a rebuilt parent strands. So the FIRST child is
  # the interface every sibling imports, small enough that it rarely conflicts,
  # and the siblings are one parallel wave on top of it.
  CONTRACT=$(jq -r 'if ((.[0].contract? // "") | type) == "string" then (.[0].contract // "") else "" end' "$SPEC" 2>/dev/null)
  case "$(printf '%s' "$CONTRACT" | tr -d '[:space:]')" in
    '') FAIL "the first child must be the CONTRACT: give it a \"contract\" field naming the exported names and paths every sibling imports, and keep it under $CONTRACT_MAXL lines" ;;
  esac

  # THE CAP IS TWO LEVELS PAST THE CONTRACT, and a deeper chain is refused
  # BEFORE anything is filed — a decomposition that needs three levels has put
  # something in level 3 that belongs in the contract. Positions are 1-based, so
  # position 1 is the contract at level 0 and every sibling starts at level 1;
  # an `after` naming an earlier sibling pushes that child one level further out.
  # `after` entries are read as "<position>: <symbol>" or a bare position, so the
  # depth is computed from exactly the declarations the filer will write down.
  LEVELS=(0)
  MAXLEVEL=0
  i=1
  while [ "$i" -lt "$N" ]; do
    n=$((i + 1))
    lvl=1
    AFTERS=$(jq -r --argjson i "$i" '(.[$i].after // []) | .[] | tostring' "$SPEC" 2>/dev/null)
    while IFS= read -r A; do
      P=$(printf '%s' "${A%%:*}" | tr -d '[:space:]')
      case "$P" in ''|*[!0-9]*) continue ;; esac
      # The contract blocks everyone and adds no level. A forward or self
      # reference is dropped at filing time (the sibling has no issue number
      # yet), so it cannot add one either.
      { [ "$P" -ge 2 ] && [ "$P" -lt "$n" ]; } || continue
      [ $(( ${LEVELS[$((P - 1))]} + 1 )) -gt "$lvl" ] && lvl=$(( ${LEVELS[$((P - 1))]} + 1 ))
    done <<<"$AFTERS"
    LEVELS+=("$lvl")
    [ "$lvl" -gt "$MAXLEVEL" ] && MAXLEVEL="$lvl"
    i="$n"
  done
  [ "$MAXLEVEL" -le 2 ] \
    || FAIL "the spec declares $MAXLEVEL chain levels beyond the contract and the cap is 2 — a chain that deep is a decomposition failure, not a dependency: whatever the deepest slice waits on belongs in the contract"

  # ---- EVERY CHILD NAMES ITS OBSERVABLE OUTCOME (BH-3954) -------------------
  # A child passes when a line STARTS with "Observable outcome" (as a markdown
  # heading, in bold, or bare) and has text after it, on the same line or
  # before the next heading. A mid-sentence mention or an empty section is not
  # an outcome. Checked last, so every older refusal keeps its own reason. A
  # spec whose filing already started (children.txt) was written under the old
  # rules and is not re-validated, or a half-filed split could never finish.
  if [ -s "$BUILD/children.txt" ]; then
    LOG "observable-outcome check skipped: filing already started (children.txt)"
  else
    NO_OUTCOME=$(jq -r '
      def head_re: "^[ \\t]*(#{1,6}[ \\t]*|\\*\\*)?observable outcome\\b";
      def has_outcome:
        split("\n") as $l
        | any(range(0; $l | length) | select($l[.] | test(head_re; "i"));
            . as $h
            | ($l[$h] | sub(head_re + "[ \\t]*(\\*\\*)?[ \\t]*:?[ \\t]*(\\*\\*)?"; ""; "i") | test("\\S"))
              or ((first($l[$h + 1:][] | select(test("\\S"))) // "") | test("\\S") and (test("^#{1,6} ") | not)));
      [to_entries[] | select((.value.body // "") | has_outcome | not) | .key + 1 | tostring] | join(", ")
    ' "$SPEC" 2>/dev/null) || FAIL "could not read the child bodies in children.json to check their observable outcomes"
    case "$NO_OUTCOME" in
      '') ;;
      *,*) FAIL "children $NO_OUTCOME have no '## Observable outcome' section: every child names the end-to-end test (or the real row/log line for infra/migration) that proves it works" ;;
      *) FAIL "child $NO_OUTCOME has no '## Observable outcome' section: every child names the end-to-end test (or the real row/log line for infra/migration) that proves it works" ;;
    esac
  fi

  # THE FILING ITSELF IS A LIBRARY (BH-982). Everything above this line is the
  # DECOMPOSER — the model call, the spec validation, the 2-5 count, the contract
  # field and the chain cap. Everything below it was the FILER, and both
  # child-filing lanes need the same filer writing the same lines, so it moved to
  # bin/lib/file-children.sh and its issues-lane module bin/lib/fc-issues.sh. The
  # bodies it writes are byte-identical to the ones this script wrote inline:
  # tests/fc-issues.bh-982-test.sh diffs them against fixtures generated from the
  # pre-move script, and the four decompose suites run unchanged.
  declare -F file_children >/dev/null 2>&1 \
    || FAIL "bin/lib/file-children.sh is missing — the child filer lives there since BH-982"
  # The library never exits: it returns nonzero and leaves the reason in
  # FC_ERROR, which is the text this lane's DECOMPOSE_FAILED line has always
  # carried. The rc is captured before the `||` composes anything, or $? would be
  # the test's.
  FC_ERROR=""
  file_children "$PROJECT" "$TICKET" "$KEY" "$BUILD" "$SPEC"
  FC_RC=$?
  [ "$FC_RC" -eq 0 ] || FAIL "${FC_ERROR:-file_children returned rc=$FC_RC}"
  # OWNS OVERLAP (BH-6384): two filed children that own the same path with no
  # hard link between them will conflict. A warning in pipeline.log, never a
  # gate: the split is already filed, and this script's rc does not move. The
  # id of child n is line n of children.txt (the board lane's dry run writes
  # none, so it falls back to the '$KEY.<n>' the filer wrote in DEPENDS).
  DL_ARGS=(); n=1
  while [ "$n" -le "$N" ]; do
    DL_ID=$(sed -n "${n}p" "$BUILD/children.txt" 2>/dev/null)
    DL_F="$BUILD/children/child-$n.md"; [ -f "$DL_F" ] || DL_F="$BUILD/children/child-$n.html"
    DL_ARGS+=("${DL_ID:-$KEY.$n}=$DL_F"); n=$((n + 1))
  done
  DL_OUT=$(timeout 30 "$(dirname "$0")/decompose-lint.sh" "${DL_ARGS[@]}" 2>&1); DL_RC=$?
  if [ "$DL_RC" -eq 0 ]; then
    while IFS= read -r DL_L; do [ -n "$DL_L" ] && LOG "$DL_L"; done <<<"$DL_OUT"
  else
    LOG "DECOMPOSE_LINT could-not-run rc=$DL_RC"
  fi
  dcp_publish "$SPEC" || true
  # >>> ticket edges (BH-6977)
  # One ticket_edges row per blocker each filed child's body declares, with the
  # child's Owns: paths as planned_files. Issues lane only, never in a dry run.
  # The bodies stay as filed. Fail-open: no stdout, rc unchanged.
  if [ "$LANE" = issues ] && [ "$DRY" != 1 ]; then
    # shellcheck source=bin/lib/ticket-edges.sh
    [ -r "$(dirname "$0")/lib/ticket-edges.sh" ] && . "$(dirname "$0")/lib/ticket-edges.sh" 2>/dev/null
    if command -v te_put_edges >/dev/null 2>&1 && [ -s "$BUILD/children.txt" ]; then
      TE_OWNS=$(mktemp "${TMPDIR:-/tmp}/te-owns.XXXXXX" 2>/dev/null) || TE_OWNS=""
      TE_N=0
      while IFS= read -r TE_ID || [ -n "$TE_ID" ]; do
        TE_N=$((TE_N + 1))
        TE_CHILD="${TE_ID##*-}"; TE_F="$BUILD/children/child-$TE_N.md"
        [ -n "$TE_OWNS" ] && [ -r "$TE_F" ] || continue
        sed -n 's/^Owns:[[:space:]]*//p' "$TE_F" | tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' > "$TE_OWNS"
        te_put_edges "$PROJECT" "$TE_CHILD" decompose "$TE_F" "$TE_OWNS" >/dev/null 2>&1 || true
      done < "$BUILD/children.txt"
      [ -n "$TE_OWNS" ] && rm -f "$TE_OWNS"
    fi
  fi
  # <<< ticket edges
  # The issues lane's children are open ai-build issues, which
  # bin/orphan-reconcile.sh enqueues; only the board lane enqueues here.
  [ "$LANE" = board ] && dcp_enqueue_children
  exit 0
fi
# ------------------------------------------------------------------ board lane
# The legacy model-filed path: it runs only on an in-app board with
# decompose-board-filer-off on (BH-3965). Without the switch the board lane
# files from the spec above and never reaches this line.
PROMPT="$DEC_UI_NOTICE""You are the tech lead for this project. Ticket $KEY (id $TICKET) is too large for one build session — its plan is over this project's decomposition threshold of $MAXL lines of product code / $MAXF files, or it sized itself XL. Your job: SPLIT it, do not build it.

Read the ticket's FULL thread (board access method + endpoints in /root/harness/prompts/$PROJECT.md) and the oversized plan at $BUILD/plan.md.

TRACER FIRST. Before you slice anything, answer one question: what is the thinnest END-TO-END path through this feature? A real trigger (a user action, a cron tick, a webhook), then a persisted result, then an observable outcome (a preview screen, an API response, or for work with no UI a real row or log line). That is child 1, THE TRACER: title it '$KEY.0: contract — <slice name>', keep it to $CONTRACT_MAXL lines of product code or fewer, and list the exported names and paths it really lands on a 'CONTRACT:' line in its description, so the siblings import working code. The tracer also pre-creates every seam two or more siblings would otherwise both edit (a fragment file or registry slot per sibling instead of a shared list each appends to, a headed section stub per sibling in a shared prompt or doc, an empty module file per sibling), so each sibling edits only its own, and add every shared seam path to that CONTRACT: line. Make it one seam file per later child, each with a one-line comment naming its owner child, and write each child's own paths on an 'Owns: <path>, <path>' line in its description; if two children must edit the same existing file, the later one says 'build after <earlier key>: same file <path>'. Stubs that do nothing are not a tracer. It lands first and the rest are built on top of it at the same time. Each sibling adds ONE CAPABILITY END TO END (for example list, create, edit, export) and touches whatever layers that capability needs. If two siblings need the same symbol, that symbol belongs in the tracer, so move it there rather than chaining them: at most 2 levels of 'build after' beyond the tracer, and a deeper chain means the split is wrong, not that the work is.

A LAYER SPLIT IS A DECOMPOSITION FAILURE, the same as a chain: a 'UI child', 'API child', 'worker child' or 'schema child' builds pieces nobody can observe until the last one lands. Slice by what a user can do, not by where the code lives.

Then:
1. Design the tracer plus 1-4 siblings, AS AN ORDERED LIST — child 1 lands first, then 2, and so on through the merge lane. Each child MUST be: UNDER THE BUDGET (at most $MAXL lines of product code across at most $MAXF files — count source only, not tests, docs, the plan, lockfiles or generated code; if a slice cannot fit, slice it again rather than declaring an exception), independently shippable (the app works after each child merges alone, in the stated order), and file-disjoint from its siblings (list each child's intended files/dirs explicitly). State each child's position explicitly as 'Order: <n> of <total>', and where a child genuinely cannot start before another, say 'build after <sibling key>' in its description — the ordering is what lets them land one after another without re-resolving the same conflicts, and file-disjointness is what lets the scheduler overlap the ones that are genuinely independent.
2. Create each child on the SAME board via the ticket-create endpoint (POST .../boards/{boardId}/tickets, shape per the prompts file). Title: '$KEY.<n>: <slice name>' — that prefix is a LABEL, not the child's key. The child's KEY is the one the board hands back from the create call ('.ticket.key'). Description must carry: 'Part of $KEY', the exact scope, the intended file list, the relevant acceptance tests from the parent plan, a '## Observable outcome' section (the one end-to-end acceptance test, or the real row/log line for infra/migration, plus the QA screens when there is UI; every child has one, the tracer included), its 'Order: <n> of <total>' line, its own size budget ('at most $MAXL product lines across $MAXF files'), and any sibling ordering. Priority: inherit the parent's.
3. Post ONE comment on the parent ticket (De-AI voice, plain, warm): this request is bigger than one change, here is how we split it, list each child key + one-line scope, and note that progress lands piece by piece with links as each part ships.
4. Write the BOARD's keys for the children you created — the ones the create calls returned — one per line, to $BUILD/children.txt, IN THE ORDER THEY SHOULD LAND. Never '$KEY.<n>': that is the title label, and a build launched under a label is a second identity for one board ticket.
5. Do NOT change any code, do NOT move the parent's status (this script parks it after you finish), do NOT build anything.

Final output line: exactly 'DECOMPOSED: <comma-separated child keys>' or 'DECOMPOSE_FAILED: <reason>'."

"$HARNESS/bin/agent-call.sh" decompose "$PROJECT" "$DECOMPOSE_M" 2400 "$BUILD/decompose-run.txt" "$PROMPT" >/dev/null 2>&1
RC=$?
if [ -s "$BUILD/children.txt" ]; then
  # The token NAME comes from bin/lib/board-creds.sh (BH-1955): none, two, or no
  # lib leaves it empty after one ALERTS line, and every board call below is
  # guarded on it — so a refusal lands in the DEC_FAIL arm, which calls nothing.
  TOKEN_VAR=""
  command -v board_token_var >/dev/null 2>&1 \
    && { TOKEN_VAR=$(board_token_var "$PROJECT" "$HENV/$PROJECT.env" run-decompose) || TOKEN_VAR=""; }
  # WHERE THIS BOARD'S API LIVES, RESOLVED ONCE (BH-1340). fleet.conf column 4
  # is the registry answer (docs/BOARD-API-CONTRACT.md) and fc_board_base gives
  # base+prefix or nothing at all. Resolved HERE rather than at each POST
  # because there are two of them — the DEC_FAIL arm below and the success tail
  # — and a base resolved twice is a base that drifts apart again, which is
  # exactly what this ticket is cleaning up.
  BOARD_BASE=""
  # board_base_var first (BH-1955): fc_board_base logs nothing, so a base with
  # no match or two would otherwise land in DEC_FAIL with no ALERTS line.
  command -v fc_board_base >/dev/null 2>&1 && command -v board_base_var >/dev/null 2>&1 \
    && board_base_var "$PROJECT" "$HENV/$PROJECT.env" run-decompose >/dev/null \
    && BOARD_BASE=$(fc_board_base "$PROJECT" 2>/dev/null)
  # >>> board child keys
  # THE CHILD'S KEY IS THE BOARD'S, THE TITLE PREFIX IS A LABEL (BH-866). The
  # prompt above says so, but a prompt is not a mechanism: the model wrote
  # `TK-1766.0/.1/.2` into children.txt, the triage prompts launched those as
  # build keys, and the board's own keys for the same tickets (TK-1784..) were a
  # second identity for the same work. job_open and the worker's double-build
  # guard both dedupe on the key, so neither could see it.
  #
  # So every `<KEY>.<n>` line is re-mapped here, from the board, to the key of
  # the ticket whose TITLE carries that label. A label the board has never heard
  # of is not a key to invent — it is a split that did not land, and it fails
  # the whole decompose rather than half-landing (the labels are kept beside the
  # failure for whoever reads it, and the parent is PARKED, because the children
  # are already filed by the time this runs — see the DEC_FAIL arm below).
  DEC_FAIL=""
  if grep -qE "^${KEY}\.[0-9]+$" "$BUILD/children.txt"; then
    BOARD_ID=""
    if [ -n "$TOKEN_VAR" ] && [ -n "$BOARD_BASE" ]; then
      BOARD_ID=$(curl -s --max-time 30 -H "Authorization: Bearer ${!TOKEN_VAR}" -H "User-Agent: curl/8" \
        "$BOARD_BASE/tickets/$TICKET" 2>/dev/null \
        | jq -r '.boardId // .ticket.boardId // ""' 2>/dev/null) || BOARD_ID=""
    fi
    if [ -z "$BOARD_ID" ]; then
      DEC_FAIL="the parent's board could not be read, so no child label could be resolved to a board key"
    else
      BOARD_TICKETS=$(curl -s --max-time 30 -H "Authorization: Bearer ${!TOKEN_VAR}" -H "User-Agent: curl/8" \
        "$BOARD_BASE/boards/$BOARD_ID/tickets" 2>/dev/null)
      : > "$BUILD/children.mapped"
      while IFS= read -r LINE; do
        [ -n "$LINE" ] || continue
        case "$LINE" in
          "$KEY".[0-9]*) : ;;
          *) printf '%s\n' "$LINE" >> "$BUILD/children.mapped"; continue ;;
        esac
        # The match is the EXACT '<label>:' title prefix. A looser one eats
        # `$KEY0.<n>` from an unrelated parent and any title that merely mentions
        # the label. Newest wins when two share a prefix, and the tie is logged —
        # never silently picked.
        # THE KEY IS OFTEN NOT IN THE LIST. project-4 — the board this ticket was
        # written from — returns `number` from its board list (CARD_SELECT in
        # `boards/[boardId]/tickets`) and formats the key from the board's
        # keyPrefix only on the single-ticket and create responses. Requiring
        # `.key` there matches zero tickets, so EVERY project-4 split whose model
        # wrote labels would DECOMPOSE_FAIL with the parent unparked — a worse
        # failure than the duplicate this block exists to stop. So the key is
        # the board's when it sends one, and otherwise the parent key's own
        # prefix plus the board number, which is exactly what formatTicketKey
        # builds on that board (TK-1766 + 1784 -> TK-1784).
        MAP=$(jq -r --arg l "$LINE" --arg pfx "${KEY%%-*}" '
          def tkey: (.key // (if (.number // null) != null and ($pfx != "")
                              then ($pfx + "-" + ((.number|tostring)))
                              else "" end));
          ( if type == "array" then . else (.tickets // .data.tickets // []) end )
          | map(select((((.title // "") | startswith($l + ":")) and (tkey != ""))))
          | (sort_by((.createdAt // .created_at // "") | tostring) | reverse) as $m
          | "\($m | length)\t\($m[0] // {} | tkey)\t\($m[0].id // "")"' <<<"$BOARD_TICKETS" 2>/dev/null)
        IFS=$'\t' read -r MCOUNT MKEY MID <<<"${MAP:-0$'\t'$'\t'}"
        case "$MCOUNT" in ''|*[!0-9]*) MCOUNT=0 ;; esac
        if [ "$MCOUNT" -eq 0 ] || [ -z "$MKEY" ]; then
          DEC_FAIL="child $LINE was filed under no board key (children.txt must carry board keys)"
          break
        fi
        [ "$MCOUNT" -gt 1 ] && LOG "WARN: $MCOUNT board tickets are titled '$LINE: …' — took the newest, $MKEY (id $MID)"
        LOG "child $LINE -> $MKEY (id $MID)"
        printf '%s\n' "$MKEY" >> "$BUILD/children.mapped"
      done < "$BUILD/children.txt"
    fi
    if [ -n "$DEC_FAIL" ]; then
      rm -f "$BUILD/children.mapped"
      mv "$BUILD/children.txt" "$BUILD/children.txt.labels"
      # PARK THE PARENT ANYWAY. By the time this arm runs the model has already
      # FILED the children on the board and posted the split comment — the only
      # thing that failed is turning their title labels into keys. A parent left
      # in todo/ready is re-claimed by the next triage tick, re-enters the size
      # gate and files a SECOND set of children on a board a client reads. That
      # is the duplicate this ticket exists to stop, so the honest outcome is:
      # park it, keep the labels next to the failure, and say plainly that the
      # children EXIST and need a human to map them. (Parking is also what the
      # success path does; the difference is only that nothing is launchable.)
      DEC_FAIL="$DEC_FAIL — the children ARE on the board under their '$KEY.<n>' title labels (see $BUILD/children.txt.labels); the parent is parked so nothing re-splits it, and a human must map the labels to board keys"
      # PARK AT THE BOARD'S OWN PREFIX (BH-1340). This POST was the second
      # hardcoded board path in the file; BH-982 moved the tail and left this
      # arm, so on a project not served at the default prefix the parent was
      # never parked and the WARN above became true.
      if [ -n "$TOKEN_VAR" ] && [ -n "$BOARD_BASE" ]; then
        if curl -s --max-time 30 -X POST -H "Authorization: Bearer ${!TOKEN_VAR}" -H "User-Agent: curl/8" \
            -H 'Content-Type: application/json' -d '{"toStatus":"in_progress","sortOrder":999999}' \
            "$BOARD_BASE/tickets/$TICKET/move" | grep -q in_progress; then
          LOG "parent parked in_progress after a FAILED re-map — its children are filed but unmapped"
        else
          LOG "WARN: could not park the parent after a failed re-map — the next tick may file a SECOND set of children"
        fi
      else
        LOG "WARN: could not park the parent after a failed re-map — the next tick may file a SECOND set of children"
      fi
      LOG "DECOMPOSE_FAILED: $DEC_FAIL"
      printf 'DECOMPOSE_FAILED: %s\n' "$DEC_FAIL" >> "$BUILD/decompose-run.txt"
      exit 1
    fi
    mv "$BUILD/children.mapped" "$BUILD/children.txt"
  fi
  # <<< board child keys
  dcp_publish "" || true
  # >>> enqueue children (BH-3970): dcp_enqueue_children, defined above
  dcp_enqueue_children
  # <<< enqueue children
  echo "$(STAMP) [$PROJECT/$KEY] decomposed into: $(paste -sd, "$BUILD/children.txt")" >> "$BUILD/pipeline.log"
  # Park the parent in_progress: a decomposed master left in todo/ready reads as
  # buildable and gets re-claimed forever — by us or by any other harness watching
  # the board (TK-138/171/119/128 all hit this, 2026-08-12). The master tracks its
  # children from here; the split comment on the thread is the human-facing record.
  # THE BOARD PREFIX IS fleet.conf COLUMN 4, not a constant (BH-982). This line
  # used to paste one hardcoded prefix onto the API base, which is a URL that
  # does not exist on a project served at /api/accounting/requests-board
  # (docs/BOARD-API-CONTRACT.md). fc_board_base answers base+prefix or nothing at
  # all, and nothing means the WARN below rather than a POST at the wrong host.
  # BOARD_BASE is resolved once above the re-map block, so the DEC_FAIL arm and
  # this tail park at the same URL. TOKEN_VAR is set in the same place, through
  # $HENV (env-path.sh's resolved dir) — re-deriving either one here from a
  # hardcoded $HARNESS/env would go stale on a box whose env dir moved, and
  # silently drop this parking POST.
  if [ -n "$TOKEN_VAR" ] && [ -n "$BOARD_BASE" ]; then
    if curl -s --max-time 30 -X POST -H "Authorization: Bearer ${!TOKEN_VAR}" -H "User-Agent: curl/8" \
        -H 'Content-Type: application/json' -d '{"toStatus":"in_progress","sortOrder":999999}' \
        "$BOARD_BASE/tickets/$TICKET/move" | grep -q in_progress; then
      echo "$(STAMP) [$PROJECT/$KEY] parent parked in_progress (master of split)" >> "$BUILD/pipeline.log"
    else
      echo "$(STAMP) [$PROJECT/$KEY] WARN: could not park parent in_progress after split" >> "$BUILD/pipeline.log"
    fi
  else
    echo "$(STAMP) [$PROJECT/$KEY] WARN: could not park parent in_progress after split" >> "$BUILD/pipeline.log"
  fi
  exit 0
fi
echo "$(STAMP) [$PROJECT/$KEY] decompose FAILED rc=$RC (no children.txt)" >> "$BUILD/pipeline.log"
exit 1
