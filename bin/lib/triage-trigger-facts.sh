#!/bin/bash
# bin/lib/triage-trigger-facts.sh — THE BUILD GATE'S ANSWER, GIVEN TO TRIAGE
# AS A FACT (BH-8933). Sourced by rt_scope (bin/lib/rt/scope.sh); defines one
# function, reads nothing at source time.
#
# The case (example-org/project-6, 2026-11-02): github-actions[bot] labelled
# #3524 ai-build, the trigger-actor gate refused it and posted "We didn't start
# a build for this one", and operator (on the trigger list) relabelled it. The
# gate allowed the relabel. Event-wake triage did not ask the gate: it read the
# older refusal comment, judged the labeler in prose and logged `skip`, so no
# queue row was made. Now triage gets the gate's own answer per scoped ticket,
# from the same reader and rule (ta_triage_fact -> ta_gh_decide in
# bin/lib/trigger-actor.sh), and the triage contract says to use it.
#
# rt_trigger_facts — reads TICK_SCOPE, PROJECT, HARNESS, TRIAGE_GH_SLUG, LOG,
# STAMP. Sets PROJECT_2_FACTS_SEC: the TRIGGER ACTOR prompt section, or empty when
# nothing applies (knob 0, empty scope, not a GitHub-Issues board, no lib, no
# slug, no issue key). Empty leaves the tick byte-for-byte what it was.
# GitHub reads only (one events page per key, plus a comments read when a label
# is ignored); no ledger write and no comment. The gate stays the only writer.
# shellcheck shell=bash

rt_trigger_facts() {
  local max gh slug keys line k d facts summary
  PROJECT_2_FACTS_SEC=""
  # Knob row: TRIAGE_TRIGGER_FACT_MAX_KEYS on the run-triage lane
  # (catalog/lanes.d/run-triage.json); 10 is its documented fallback.
  max="${TRIAGE_TRIGGER_FACT_MAX_KEYS:-10}"
  case "$max" in ''|*[!0-9]*) max=10 ;; esac
  [ "$max" -gt 0 ] || return 0
  [ -n "${TICK_SCOPE:-}" ] || return 0
  command -v triage_shard_key >/dev/null 2>&1 && command -v triage_shard_gh >/dev/null 2>&1 || return 0
  gh=$(triage_shard_gh "$HARNESS" "$PROJECT" 2>/dev/null)
  [ "$gh" = 1 ] || return 0
  [ -r "$HARNESS/bin/lib/trigger-actor.sh" ] || return 0
  slug="${TRIAGE_GH_SLUG:-}"
  [ -n "$slug" ] || slug=$("$HARNESS/bin/fleet-conf.sh" "$PROJECT" repo 2>/dev/null || true)
  [ -n "$slug" ] || return 0
  keys=$(while IFS= read -r line; do
           line=${line#'[HOTFIX] '}
           triage_shard_key board "$PROJECT" "$gh" "$line" 2>/dev/null
         done <<<"$TICK_SCOPE" | grep -E '^[0-9]+$' | awk '!seen[$0]++' | head -n "$max")
  [ -n "$keys" ] || return 0
  d=$(mktemp -d "${TMPDIR:-/tmp}/trigger-fact.XXXXXX" 2>/dev/null) || return 0
  # A subshell: trigger-actor.sh's deps (gh-rest, jobs-client, lane-switch)
  # load there and never into the triage shell.
  facts=$( # shellcheck source=bin/lib/trigger-actor.sh
           . "$HARNESS/bin/lib/trigger-actor.sh" 2>/dev/null || exit 0
           command -v ta_triage_fact >/dev/null 2>&1 || exit 0
           while IFS= read -r k; do
             ta_triage_fact "$PROJECT" "$slug" "$k" "$d" 2>/dev/null
           done <<<"$keys" )
  rm -rf "$d"
  [ -n "$facts" ] || return 0
  summary=$(printf '%s\n' "$facts" | sed -nE 's/^([0-9]+) :: ([a-z-]+) ([^ ]+).*/\1=\2 \3/p' | paste -sd, - | sed 's/,/, /g')
  echo "${STAMP:-$(date -u '+%Y-%m-%d %H:%M:%SZ')} [$PROJECT] trigger-actor facts: $summary" >> "${LOG:-$HARNESS/logs/$PROJECT.log}" 2>/dev/null
  PROJECT_2_FACTS_SEC="TRIGGER ACTOR (deterministic — bin/lib/trigger-actor.sh, the same reader and rule the build gate uses):
$facts

This is the build gate's own answer. Do not decide who may start a build yourself, and do not skip a ticket because of who added the label or because of an older 'We didn't start a build for this one' comment. allow: the label counts; any older refusal comment is stale, so triage the ticket as triggered (queue or launch it per the SOP). ignore: skip it as \`skip :: trigger-actor ignore <why>\`. unverifiable, or no line for a ticket: triage it on its other merits; the build gate decides at launch."
  return 0
}
