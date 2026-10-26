#!/bin/bash
# shellcheck shell=bash
# module: gate-record
# bin/lib/lead-review/gate-record.sh — the selection-gate record check (BH-8062).
# A builder runs the batch's test selection on the fleet test host before it
# opens a PR (bin/selection-gate.sh) and writes one marker into the PR body:
#   <!-- selection-gate: head=<40-hex> suites=<n> rc=<0|could-not-run|no-selection|off> -->
# rc=off is the record of a build with the gate knob SELECTION_GATE at 0 (the
# operator turned the gate off); it is accepted like the other three. It is not
# the review knob's mode `off` below, which skips the check altogether.
# The lead review cannot see the build dir, so this marker is the record. A
# builder PR (head branch ticket/*) whose body has no record for its head, or a
# record for another head, is a BLOCK with no agent call (nothing is billed).
# Any other branch (hotfix/*, fix/*) gets a [NOTE] in the reviewer's prompt.
# WHERE IT APPLIES (r3, F1): only when the PR's merge base with its base
# branch has bin/selection-gate.sh in its tree. Another project's repo has no
# gate, and a PR built on a main from before the gate merged had none to run:
# both are `ok - n/a`. That is the cutover, with no date knob.
# A MOVED HEAD (r3, F2): a record for head H is accepted for the PR head S when
# patch_same (bin/lib/patch-same.sh) says S carries exactly H's patch (the same
# rule that rebinds an approval). Any other mismatch is a refusal.
# Sourced by bin/lead-review.sh through bin/lib/lead-review/load.sh, never run.
# Defines functions only. Reads LEAD_REVIEW_GATE_RECORD (catalog knob, row
# lane.lead-review.lead_review_gate_record: block|note|off, default block) at
# the call, through lane_knob when it is loaded (the settings cache, TTL
# LANE_GATE_CACHE_S), so a row set after the tick started applies.

LR_GR_RE='^<!-- selection-gate: head=([0-9a-f]{40}) suites=([0-9]+) rc=(0|could-not-run|no-selection|off) -->$'

# lr_gate_record_mode — block|note|off. Unset, empty or any other value is
# block, the code fallback for row lane.lead-review.lead_review_gate_record.
# The row is read at the call (BH-8349): the env value lane_env_apply exported
# at tick start is only the fallback when lane_knob is not loaded.
lr_gate_record_mode() {
  local m="${LEAD_REVIEW_GATE_RECORD:-}"
  command -v lane_knob >/dev/null 2>&1 && m=$(lane_knob lead-review LEAD_REVIEW_GATE_RECORD)
  case "$m" in
    note|off) printf '%s' "$m" ;;
    *) printf block ;;
  esac
}

# lr_gate_record <body> <sha> <head_ref> <mode> <repo_dir> <base> — one line:
#   ok <suites> <rc>     one distinct exact marker, and it names <sha>
#                        (<rc> 0, could-not-run, no-selection or off)
#   ok <suites> <rc> rebound=<how>  it names another head that patch_same
#                        proves carries the same patch (identical, main-merge,
#                        patch-id)
#   ok - off             mode off: nothing is checked (`ok 0 off` is a record
#                        with rc=off, a different answer)
#   ok - n/a             the merge base of <sha> with origin/<base> has no
#                        bin/selection-gate.sh: no gate existed for this PR
#   refuse missing       no selection-gate marker at all
#   refuse head=<sha>    the one marker names another head (40 hex: two heads
#                        can share their first 12)
#   refuse malformed     a selection-gate marker that does not match exactly,
#                        or two markers that differ
#   note <why>           a refusal on a head_ref that is not ticket/*, or in
#                        mode note, or a merge base this box cannot read (a
#                        read failure is never a BLOCK)
lr_gate_record() {
  local body="${1:-}" sha="${2:-}" ref="${3:-}" mode="${4:-block}" rd="${5:-}" base="${6:-main}" lines line n mh ms mr ans why mb how
  [ "$mode" = off ] && { echo "ok - off"; return 0; }
  # F1: does a gate exist for this PR? Local git only, no network.
  if ! mb=$(git -C "$rd" merge-base "origin/$base" "$sha" 2>/dev/null) || ! [[ "$mb" =~ ^[0-9a-f]{40}$ ]]; then
    echo "note could not read the merge base of ${sha:0:12} with origin/$base, so the selection-gate record was not checked"; return 0
  fi
  git -C "$rd" cat-file -e "$mb:bin/selection-gate.sh" 2>/dev/null || { echo "ok - n/a"; return 0; }
  lines=$(grep -oE '<!--[[:space:]]*selection-gate:[^>]*>' <<<"$body" | sort -u)
  n=$(grep -c . <<<"$lines")
  if [ "$n" = 0 ]; then ans="refuse missing"
  elif [ "$n" -gt 1 ]; then ans="refuse malformed"
  else
    line=$lines
    if [[ "$line" =~ $LR_GR_RE ]]; then
      mh="${BASH_REMATCH[1]}"; ms="${BASH_REMATCH[2]}"; mr="${BASH_REMATCH[3]}"
      if [ "$mh" = "$sha" ]; then echo "ok $ms $mr"; return 0; fi
      # F2: the head moved; accept it only when the patch did not.
      command -v patch_same >/dev/null 2>&1 || { [ -r "${HARNESS:-${H:-}}/bin/lib/patch-same.sh" ] && . "${HARNESS:-${H:-}}/bin/lib/patch-same.sh" 2>/dev/null; }
      if command -v patch_same >/dev/null 2>&1 && how=$(patch_same "$rd" "origin/$base" "$mh" "$sha" 2>/dev/null) && [ -n "$how" ]; then
        echo "ok $ms $mr rebound=$how"; return 0
      fi
      ans="refuse head=$mh"
    else ans="refuse malformed"
    fi
  fi
  case "$ref" in ticket/*) [ "$mode" = note ] && why="LEAD_REVIEW_GATE_RECORD=note" ;; *) why="$ref is not a builder branch" ;; esac
  [ -z "${why:-}" ] && { echo "$ans"; return 0; }
  echo "note $(_lr_gr_finding "$ans" "$sha") ($why)"
}

# _lr_gr_finding <refuse-answer> <sha> — the finding text for it.
_lr_gr_finding() {
  case "$1" in
    "refuse head="*) printf 'the selection-gate record names head %s, not %s' "${1#refuse head=}" "$2" ;;
    "refuse malformed") printf 'the selection-gate record for head %s is malformed' "${2:0:12}" ;;
    *) printf 'no selection-gate record for head %s' "${2:0:12}" ;;
  esac
}

# lr_gate_record_report <rvline> <key> <repo> <pr> <sha> <bfp> <refuse-answer>
#   The deterministic BLOCK report, the migration-lint report's shape.
lr_gate_record_report() {
  printf '%s# Lead review %s (%s#%s at %s)\n\n- verdict: BLOCK\n- selection gate: %s\n- reviewer model: none:gate-record\n- pr body: %s\n\nFindings\n' \
    "$1" "$2" "$3" "$4" "$5" "${7#refuse }" "$6"
  printf -- '- [BLOCK core-flow-broken] %s. The builder runs the batch selection on the test host before it opens the PR and writes that record into the body (bin/selection-gate.sh); rebuild or re-run the gate on this head.\n' \
    "$(_lr_gr_finding "$7" "$5")"
  printf '\nVERDICT: BLOCK\n'
}

# lr_gate_record_section — the reviewer prompt's "## Selection gate" section,
# only when LR_GR_NOTE is set (a [NOTE] the host block left).
lr_gate_record_section() {
  [ -n "${LR_GR_NOTE:-}" ] || return 0
  printf '\n## Selection gate\n%s\n' "$LR_GR_NOTE"
}
