#!/bin/bash
# bin/lib/pr-record-serve.sh — BH-8457: the merge-state read of an open-list
# row, answered from the PR record (bin/lib/pr-record.sh, BH-8067) instead of
# one GitHub `pulls/{n}` GET per row per tick. Sourced, never executed.
# bin/lib/gh-pr-list.sh calls it when the lane exports HPL_PR_RECORD=1; only
# bin/merge-conductor.sh does.
#
#   prr_serve_state <owner/repo> <number> <list-head> <outfile>
#       rc 0: <outfile> holds {head:{sha}, mergeable_state, mergeable}, built
#       from the record with no GitHub call. rc 1: a miss, nothing written; the
#       caller reads as before. ONE jobs GET (pr_record_peek), and none when the
#       knob is 0 or the list head is not a 40-hex sha. It serves only when ALL
#       of these hold:
#         the row is this repo's and this number's, state "open";
#         age_s (the worker's now minus the record's last write) is 0..knob;
#         head_sha, lower-cased, is the list head, lower-cased;
#         mergeable_state is one of the words GitHub computes (a base push or
#         GitHub's own "unknown" stores NULL, BH-8151: a miss).
#       mergeable is false for dirty and true for every other served state.
#       Each call appends `RSERVED <n>` or `RMISS <n>` to $PRS_COUNT_FILE when
#       it is set; the conductor logs them as `<slug> PR-RECORD served= miss=`.
#
#   prr_serve_note <owner/repo> <number> <body-file>
#       After a LIVE pulls/{n} read: the fields a GitHub read fills, written
#       into the record (source github), so the next tick is served. Always
#       rc 0. A failed put is one logs/pr-record.log line:
#         <UTC> serve-note <repo>#<n> put=failed
#
#   prr_serve_max_age
#       The resolved PR_RECORD_SERVE_MAX_AGE_S as a non-negative integer.
#
#   prr_serve_seq_max_age
#       BH-10215: the resolved PR_RECORD_SERVE_SEQ_MAX_AGE_S (fallback 3600).
#
# BH-10215: THE BASE SEQUENCE, step `record` only. prr_serve_state reads the
# step of lane merge-conductor (prr_step, bin/lib/prr-shadow.sh) when prr_step
# is defined; without it, and in steps off and shadow, the rule above is the
# rule, with the same calls. In step record the sequence rule EXTENDS the age
# rule (r3; rounds 1-2 replaced it and broke tests/mc-record-tick.bh-9938).
# After the checks above (repo, number, open, head, state), in this order:
#   1 SEQ-MATCH: row.mergeable_base_seq is an integer and equals the repo's
#     current sequence for row.base_ref (GET /api/pr-base-seqs, which the
#     worker raises at each push webhook to that branch), and
#     fields_at.mergeable_state == fields_at.mergeable_base_seq (both came
#     from the same GitHub-read PUT), and mergeable_state is one CI and
#     reviews cannot move (clean, dirty, behind, draft; r5). Serves while
#     the STATE is 0..PR_RECORD_SERVE_SEQ_MAX_AGE_S old. Older, or blocked/
#     unstable/has_hooks (a check run or a review moves those with no base
#     push): rule 3. The state's age is age_s + (refreshed_at -
#     fields_at.mergeable_state): worker times only, no box clock (r6). age_s
#     alone is not the state's age: a webhook write of another field (checks,
#     labels) moves refreshed_at, and the 3600 s backstop for a lost push
#     webhook would then never run out (the BH-10257 slice 2 rule).
#   2 SEQ-MOVED: both sequences are known and differ. A miss at ANY age.
#   3 AGE: every other row (no row sequence, sequences unreadable, no row for
#     the base, a later webhook write of mergeable_state) is the rule above,
#     unchanged: it serves only to PR_RECORD_SERVE_MAX_AGE_S. A sequence that
#     cannot be read is never "not moved": it gets no age extension.
# A miss whose cause is the sequence (rule 2, or rule 3 reached for want of a
# usable sequence) appends `RMISS-SEQ <n>` to $PRS_COUNT_FILE beside `RMISS <n>`.
# The sequences are ONE jobs GET per repo per conductor tick: the answer is
# kept in tick_memo_file baseseq <repo> (bin/lib/mc/locks.sh) when the caller
# has it and MC_TICK_ID is set. A failed read writes no positive memo; it
# writes the negative memo baseseq-miss (r4), so the next row in the same tick
# misses with no new request. In step shadow
# prr_serve_state reads the sequences too (no GitHub call), so the note can
# carry them. prr_serve_note (steps shadow and record) adds
# mergeable_base_seq to its PUT from that memo only (never a new read): the
# sequence read BEFORE the GitHub read, so a push that lands during the read
# leaves the row one sequence behind, and the next tick misses.
#
# The knob PR_RECORD_SERVE_MAX_AGE_S (catalog/lanes.d/_lib.pr-record.knobs.d/)
# is read like pr-record.sh's own: lane_knob when the caller has it, else the
# environment; not a non-negative integer = 120 plus one pr-record.log line.
[ -n "${_PRRS_LOADED:-}" ] && return 0
_PRRS_LOADED=1
# shellcheck source=bin/lib/pr-record.sh
command -v pr_record_peek >/dev/null 2>&1 || . "${BASH_SOURCE[0]%/*}/pr-record.sh" 2>/dev/null
_PRRS_DEFAULT_MAX_AGE_S=120   # fallback only: the knob is PR_RECORD_SERVE_MAX_AGE_S in catalog/lanes.d/_lib.pr-record.knobs.d/
_PRRS_DEFAULT_SEQ_MAX_AGE_S=3600   # fallback only: the knob is PR_RECORD_SERVE_SEQ_MAX_AGE_S in catalog/lanes.d/_lib.pr-record.knobs.d/
_PRRS_STATES='["clean","dirty","blocked","unstable","has_hooks","behind","draft"]'
# BH-10215 r5: the states rule 1 (SEQ-MATCH) may serve past the age knob. CI
# (check_run, status) and reviews move blocked/unstable/has_hooks with no base
# push and no mergeable_state write, so those stay on rule 3 (the age rule),
# the same split _hpl_state_get uses (bin/lib/gh-pr-list.sh, BH-1486 F1).
_PRRS_SEQ_STATES='["clean","dirty","behind","draft"]'

prr_serve_max_age() {
  command -v _prr_knob >/dev/null 2>&1 || { printf '%s' "$_PRRS_DEFAULT_MAX_AGE_S"; return 0; }
  _prr_knob PR_RECORD_SERVE_MAX_AGE_S "$_PRRS_DEFAULT_MAX_AGE_S"
}

prr_serve_seq_max_age() {
  command -v _prr_knob >/dev/null 2>&1 || { printf '%s' "$_PRRS_DEFAULT_SEQ_MAX_AGE_S"; return 0; }
  _prr_knob PR_RECORD_SERVE_SEQ_MAX_AGE_S "$_PRRS_DEFAULT_SEQ_MAX_AGE_S"
}

# _prrs_step — the step of lane merge-conductor; `shadow`-like "" when prr_step is not defined.
_prrs_step() { command -v prr_step >/dev/null 2>&1 && prr_step merge-conductor; }

# _prrs_base_seqs <owner/repo> [memo-only] — the repo's {base_ref: seq} object
# on stdout, rc 0. rc 1 on a failed or malformed read, or (memo-only) when this
# tick holds no memo. memo-only never makes a request.
# BH-10215 r4: a failed or malformed read writes the NEGATIVE tick memo
# (tick_memo_file baseseq-miss <repo>, an empty marker). Later calls in the
# same tick see it and return rc 1 with no request, so an unreadable route
# costs 1 jobs GET per repo per tick, not 1 per row. The marker is a miss,
# never "not moved". Outside a tick there is no memo of either kind.
_prrs_base_seqs() {
  local lr memo="" neg="" out obj
  lr=$(printf '%s' "${1:-}" | tr 'A-Z' 'a-z')
  [[ "$lr" =~ ^[a-z0-9_.-]+/[a-z0-9_.-]+$ ]] || return 1
  if [ -n "${MC_TICK_ID:-}" ] && [ "${MC_READ_MEMO:-1}" != 0 ] && command -v tick_memo_file >/dev/null 2>&1; then
    memo=$(tick_memo_file baseseq "$lr" 2>/dev/null)
    neg=$(tick_memo_file baseseq-miss "$lr" 2>/dev/null)
  fi
  if [ -n "$memo" ] && [ -s "$memo" ] && jq -ce 'objects' "$memo" 2>/dev/null; then return 0; fi
  [ "${2:-}" != memo-only ] || return 1
  [ -n "$neg" ] && [ -e "$neg" ] && return 1
  command -v _prr_client >/dev/null 2>&1 && _prr_client || return 1
  if ! out=$(_jobs_req GET "/api/pr-base-seqs?repo=$lr" 2>/dev/null) \
     || ! obj=$(jq -ce 'if (.rows | type) == "array"
      and all(.rows[]; (.base_ref | type) == "string" and (.seq | type) == "number" and .seq == (.seq | floor) and .seq >= 0)
    then .rows | map({key: .base_ref, value: .seq}) | from_entries else error("not a base-seq answer") end' <<<"$out" 2>/dev/null); then
    [ -n "$neg" ] && mkdir -p "${neg%/*}" 2>/dev/null && : > "$neg" 2>/dev/null
    return 1
  fi
  if [ -n "$memo" ] && mkdir -p "${memo%/*}" 2>/dev/null; then
    printf '%s\n' "$obj" > "$memo.tmp.$BASHPID" 2>/dev/null && mv -f "$memo.tmp.$BASHPID" "$memo" 2>/dev/null
    rm -f "$memo.tmp.$BASHPID" 2>/dev/null
  fi
  printf '%s\n' "$obj"
}

# _prrs_row_ok <row> <slug> <n> <head> <max> — the checks every step shares.
_prrs_row_ok() {
  jq -e --arg r "$(printf '%s' "$2" | tr 'A-Z' 'a-z')" --argjson n "$3" --arg h "$4" \
      --argjson max "$5" --argjson ok "$_PRRS_STATES" '
      ((.repo // "") | ascii_downcase) == $r and .number == $n and .state == "open"
      and (.age_s | type) == "number" and .age_s >= 0 and .age_s <= $max
      and ((.head_sha // "") | ascii_downcase) == $h
      and ((.mergeable_state // "") as $m | $ok | index($m) != null)' <<<"$1" >/dev/null 2>&1
}

# _prrs_serve <row> <out> — write the served body; rc of the write.
_prrs_serve() {
  jq -c '{head: {sha: (.head_sha | ascii_downcase)}, mergeable_state,
      mergeable: (.mergeable_state != "dirty")}' <<<"$1" > "$2" 2>/dev/null
}

_prrs_count() { [ -n "${PRS_COUNT_FILE:-}" ] && printf '%s %s\n' "$1" "$2" >> "$PRS_COUNT_FILE" 2>/dev/null; return 0; }

prr_serve_state() {
  local slug="${1:-}" n="${2:-}" head out="${4:-}" max row step seqs
  head=$(printf '%s' "${3:-}" | tr 'A-F' 'a-f')
  step=$(_prrs_step)
  if [ "$step" = record ]; then
    # BH-10215 r3: the sequence rule EXTENDS the age rule (see the header).
    # rule 1 SEQ-MATCH serves to the seq knob; rule 2 SEQ-MOVED misses at any
    # age; rule 3 is today's age rule for every other row.
    local smax verdict
    smax=$(prr_serve_seq_max_age); max=$(prr_serve_max_age)
    seqs=$(_prrs_base_seqs "$slug" 2>/dev/null) || seqs=null
    if [ -n "$out" ] && { [ "$smax" -gt 0 ] || [ "$max" -gt 0 ]; } && [[ "$head" =~ ^[0-9a-f]{40}$ ]] \
       && command -v pr_record_peek >/dev/null 2>&1 && row=$(pr_record_peek "$slug" "$n" 2>/dev/null) \
       && _prrs_row_ok "$row" "$slug" "$n" "$head" 9007199254740991; then
      # verdict: serve | moved | old-seq (matched, over the seq knob, or a CI-movable state) | seq (no usable sequence)
      verdict=$(jq -r --argjson s "$seqs" --argjson smax "$smax" --argjson seqok "$_PRRS_SEQ_STATES" '
          def _t: sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601;
          if ((.mergeable_base_seq | type) == "number" and .mergeable_base_seq == (.mergeable_base_seq | floor)
              and ($s | type) == "object" and (.base_ref | type) == "string"
              and ($s[.base_ref] | type) == "number") | not then "seq"
          elif $s[.base_ref] != .mergeable_base_seq then "moved"
          elif (.fields_at | type) != "object" or (.fields_at.mergeable_state | type) != "string"
              or .fields_at.mergeable_state != .fields_at.mergeable_base_seq then "seq"
          elif (.mergeable_state as $m | $seqok | index($m)) == null then "old-seq"
          elif $smax > 0 and (try (.age_s + ((.refreshed_at | _t) - (.fields_at.mergeable_state | _t))) catch -1) as $sa
              | ($sa >= 0 and $sa <= $smax) then "serve"
          else "old-seq" end' <<<"$row" 2>/dev/null)
      case "$verdict" in
        serve) _prrs_serve "$row" "$out" && { _prrs_count RSERVED "$n"; return 0; } ;;
        moved) : ;;
        seq|old-seq)
          if [ "$max" -gt 0 ] && _prrs_row_ok "$row" "$slug" "$n" "$head" "$max" && _prrs_serve "$row" "$out"; then
            _prrs_count RSERVED "$n"; return 0
          fi ;;
      esac
      case "$verdict" in moved|seq) _prrs_count RMISS-SEQ "$n" ;; esac
    fi
    [ -n "$out" ] && : > "$out" 2>/dev/null
    _prrs_count RMISS "$n"
    return 1
  fi
  # Steps off and shadow, and no prr_step: the age rule, unchanged. Shadow
  # reads the sequences first (the tick memo), so prr_serve_note can carry them.
  [ "$step" = shadow ] && _prrs_base_seqs "$slug" >/dev/null 2>&1
  max=$(prr_serve_max_age)
  if [ -n "$out" ] && [ "$max" -gt 0 ] && [[ "$head" =~ ^[0-9a-f]{40}$ ]] \
     && command -v pr_record_peek >/dev/null 2>&1 && row=$(pr_record_peek "$slug" "$n" 2>/dev/null) \
     && _prrs_row_ok "$row" "$slug" "$n" "$head" "$max" && _prrs_serve "$row" "$out"; then
    _prrs_count RSERVED "$n"
    return 0
  fi
  [ -n "$out" ] && : > "$out" 2>/dev/null
  _prrs_count RMISS "$n"
  return 1
}

prr_serve_note() {
  local mapped step seqs seq
  command -v _prr_map >/dev/null 2>&1 || return 0
  mapped=$(_prr_map < "${3:-/dev/null}")
  [ -n "$mapped" ] && [ "$mapped" != "{}" ] || return 0
  # BH-10215: the sequence read before the GitHub read (the tick memo only).
  step=$(_prrs_step)
  if { [ "$step" = shadow ] || [ "$step" = record ]; } && seqs=$(_prrs_base_seqs "$1" memo-only); then
    seq=$(jq -r --argjson s "$seqs" '(.base.ref // "") as $b | $s[$b] // empty' "${3:-/dev/null}" 2>/dev/null)
    [[ "$seq" =~ ^[0-9]{1,15}$ ]] && mapped=$(jq -c --argjson q "$seq" '. + {mergeable_base_seq: $q}' <<<"$mapped")
  fi
  pr_record_put "$1" "$2" github "$mapped" >/dev/null 2>&1 && return 0
  _prr_log "serve-note $(_prr_lower "$1")#$2 put=failed"
  return 0
}
