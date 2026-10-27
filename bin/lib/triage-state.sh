#!/bin/bash
# bin/lib/triage-state.sh — the per-ticket, DB-backed triage-state gate
# (TRIAGE-STATE, the operator 2026-09-28: "the triage should status-track with a
# database on each ticket, deterministically, before it spends tokens to see if
# it even needs to triage"). Doc: docs/TRIAGE-STATE.md. Sourced by
# bin/lib/rt/shards.sh, bin/lib/rt/launch.sh and bin/triage-shard.sh; defines
# functions only, nothing runs on source.
#
# THE GAP. bin/triage-gate.sh decides per TICK: once anything on the board or
# the queue moves, the whole scope goes back to the model. On 2026-09-28
# cromford re-triaged 13 unchanged tickets every ~20 minutes at $8-15 a
# tick, and its one buildable ticket was re-triaged instead of built.
#
# THE GATE. One triage_state row per ticket (worker/jobs, the TRIAGE-STATE
# block): the model's last verdict and verdict_hash, the INPUT HASH that verdict
# was made against. ts_precheck hashes every open ticket's inputs again
# (bin/triage-state.py: the thread minus our own comments — bin/triage-signal.py's
# rule, imported — its labels minus ours, and the state of every ticket and PR it
# names) and decides, per ticket, BEFORE any model call:
#   llm new|changed|recheck-due|unhashable|rows-unreadable   -> the model set
#   skip unchanged:<verdict>                                  -> no call
#   enqueue            a `buildable` verdict, unchanged, nothing building it,
#                      not held -> bin/run-build.sh, no call
#   skip buildable-owned:<what> | buildable-held:<why>
# A thread is read only when its board entry moved (or nothing is cached for
# it): a webhook naming it or a due recheck no longer forces a read (BH-3921).
# Otherwise the cached raw thread is re-hashed against the current board
# fingerprint, so a dependency changing state still moves the hash for free.
# The reads ROTATE (BH-3920): webhook-named keys first, then the key least
# recently tried, so N keys needing a read are all read within
# ceil(N / TRIAGE_STATE_MAX_FETCH) ticks. A key past the cap is `skip
# deferred:cap` (`skip deferred:budget` on a low GitHub budget): carried to the
# next tick, never sent to the model unread. Under enforce it is listed in
# deferred.keys, and bin/triage-gate.sh step 1d answers `RUN ts-deferred` until
# the list drains (never while a GitHub board's budget is low).
#
# ROLLOUT is a settings row, lib.triage-state.triage_state_mode:
#   off      nothing runs, nothing is written
#   shadow   (default) every decision is computed, logged to the lane log and
#            recorded on the row (last_decision); the tick is untouched
#   enforce  the decisions are applied (ts_tick below)
# Kill switch: lane_switch triage-state-off file (settings row
# switch.triage-state-off, else flags/triage-state-off) = off.
#
# FAIL-OPEN, EVERY DIRECTION. No board fingerprint, no python, an unreachable
# worker, an unreadable thread, the fetch cap spent, a low GitHub budget: the
# ticket is in the model set, never "unchanged", and the tick runs as it did.
#
# Knobs (catalog/lanes.d/_lib.triage-state.json), settings rows through
# lib_env_apply, then env:
#   TRIAGE_STATE_MODE          off | shadow | enforce (default shadow)
#   TRIAGE_STATE_TTL_S         a verdict's life before a recheck (default 0: no
#                              timer, except defer-like and the client nudge)
#   TRIAGE_STATE_CLIENT_NUDGE_S
#                              a client-turn verdict's recheck (default 1209600,
#                              0 = off)
#   TRIAGE_STATE_MAX_FETCH     thread reads per tick (default 30)
#   TRIAGE_STATE_HANDED_NO_DECISION_BACKOFF_S
#                              how long a ticket an rc-0 session returned no
#                              DECISION for is held off the model (default 7200)
#   TRIAGE_STATE_ENQUEUE_MAX   launches per tick in enforce (default 3)
#   TRIAGE_STATE_SELF_LABELS   labels we write, kept out of the hash
#                              (default ai-build,dequeued,stale-conflict,broke)

# The root is HARNESS, then the caller's H, else none (BH-2613,
# docs/notes/2026-09-26-BH-2613-lib-root-resolution.md; the entry point owns
# the /root/harness default). With no root the lib decides nothing and writes
# nothing: ts_precheck leaves TS_MODE=off (the tick runs as it would), the
# recorder records nothing, the kill-switch file reads as absent, and no path
# is ever built from the empty root.
_ts_h() { printf '%s' "${HARNESS:-${H:-}}"; }
_ts_now() { date -u +%s; }
_ts_iso() { date -u -d "@$1" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -r "$1" '+%Y-%m-%dT%H:%M:%SZ'; }
_ts_log() { # _ts_log <line> — the project's lane log, stamped like every tick line
  local h; h=$(_ts_h)
  [ -n "${LOG:-}" ] || [ -n "$h" ] || return 0
  printf '%s [%s] %s\n' "${STAMP:-$(date -u '+%Y-%m-%d %H:%M:%SZ')}" "${PROJECT:-?}" "$1" >> "${LOG:-$h/logs/${PROJECT:-unknown}.log}" 2>/dev/null
}
_ts_int() { # _ts_int <value> <default> <min>
  case "${1:-}" in ''|*[!0-9]*) printf '%s' "$2" ;; *) [ "$1" -ge "$3" ] && printf '%s' "$1" || printf '%s' "$3" ;; esac
}

# _ts_libs — the helpers this file leans on, each loaded only when the caller
# has not already: the jobs client (triage_state_*), the lane gate / switch
# (knobs, kill switch), the REST contract and the hold vocabulary.
_ts_libs() {
  local h; h=$(_ts_h)
  [ -n "$h" ] || return 0
  # BH-1138: bin/triage-state.py imports bin/triage-signal.py, and an import
  # writes bytecode beside the module. Every python call below runs after this.
  export PYTHONDONTWRITEBYTECODE=1
  if ! command -v triage_state_list >/dev/null 2>&1; then
    # shellcheck source=/dev/null
    [ -r "$h/bin/jobs-client.sh" ] && . "$h/bin/jobs-client.sh" 2>/dev/null
  fi
  if ! command -v lane_switch >/dev/null 2>&1; then
    # shellcheck source=bin/lib/lane-switch.sh
    [ -r "$h/bin/lib/lane-switch.sh" ] && . "$h/bin/lib/lane-switch.sh" 2>/dev/null
  fi
  if ! command -v gh_rest >/dev/null 2>&1; then
    # shellcheck source=bin/lib/gh-rest.sh
    [ -r "$h/bin/lib/gh-rest.sh" ] && . "$h/bin/lib/gh-rest.sh" 2>/dev/null
  fi
  if ! command -v hold_classify >/dev/null 2>&1; then
    # shellcheck source=bin/lib/hold.sh
    [ -r "$h/bin/lib/hold.sh" ] && . "$h/bin/lib/hold.sh" 2>/dev/null
  fi
  if ! command -v ts_pr_precheck >/dev/null 2>&1; then
    # shellcheck source=bin/lib/triage-state-pr.sh
    [ -r "$h/bin/lib/triage-state-pr.sh" ] && . "$h/bin/lib/triage-state-pr.sh" 2>/dev/null
  fi
  if ! command -v vd_standing >/dev/null 2>&1; then
    # shellcheck source=bin/lib/verdicts.sh
    [ -r "$h/bin/lib/verdicts.sh" ] && . "$h/bin/lib/verdicts.sh" 2>/dev/null
  fi
  return 0
}
# The BH-3921 hook modules, beside this file. Never this file's last statement:
# bin/lib/rt/shards.sh runs `. lib && ts_tick`. A box mid-sync without one runs
# the tick as before (a missing hook is rc 127, which no call site reads as handled).
# shellcheck source=bin/lib/triage-state-unreadable.sh
[ -r "$(dirname "${BASH_SOURCE[0]}")/triage-state-unreadable.sh" ] && . "$(dirname "${BASH_SOURCE[0]}")/triage-state-unreadable.sh"
# shellcheck source=bin/lib/triage-state-waste.sh
[ -r "$(dirname "${BASH_SOURCE[0]}")/triage-state-waste.sh" ] && . "$(dirname "${BASH_SOURCE[0]}")/triage-state-waste.sh"

# ts_mode <harness> <project> — off | shadow | enforce. The kill switch first;
# then the settings rows for this lib (per project, then fleet); then the env.
# Anything unreadable is `shadow`, which changes nothing a tick does.
ts_mode() {
  local p="${2:-${PROJECT:-}}" m
  _ts_libs
  # No lane-switch lib (a box mid-sync): the file alone decides, as it would.
  command -v lane_switch >/dev/null 2>&1 || lane_switch() { [ -n "$(_ts_h)" ] && [ -e "$(_ts_h)/flags/$1" ]; }
  lane_switch triage-state-off file && { printf 'off'; return 0; }
  command -v lib_env_apply >/dev/null 2>&1 && lib_env_apply triage-state "$p" >/dev/null 2>&1
  m="${TRIAGE_STATE_MODE:-shadow}"
  case "$m" in off|shadow|enforce) printf '%s' "$m" ;; *) printf 'shadow' ;; esac
}

# _ts_knobs <project> — this lib's settings rows into THIS shell's environment
# (lib_env_apply exports only where a row exists). Called in the caller's shell,
# never inside $( ), or the rows would die with the subshell.
_ts_knobs() {
  _ts_libs
  command -v lib_env_apply >/dev/null 2>&1 && lib_env_apply triage-state "${1:-${PROJECT:-}}" >/dev/null 2>&1
  return 0
}

# ts_ttl — the per-ticket sweep (BH-3921): 0 for 0, unset, empty or junk (a
# verdict with unchanged inputs is never re-offered on a timer); any other
# value is floored at 600.
ts_ttl() {
  case "${TRIAGE_STATE_TTL_S:-}" in ''|*[!0-9]*) printf '0' ;; *) [ "$TRIAGE_STATE_TTL_S" -eq 0 ] && printf '0' || _ts_int "$TRIAGE_STATE_TTL_S" 0 600 ;; esac
}
# ts_nudge — a client-turn verdict (needs_clarification / waiting_client /
# waiting_on=client) comes back to the model this long after its verdict: 0 is
# off, junk is the default, floored at 3600.
ts_nudge() {
  case "${TRIAGE_STATE_CLIENT_NUDGE_S:-}" in ''|*[!0-9]*) ;; *) [ "$TRIAGE_STATE_CLIENT_NUDGE_S" -eq 0 ] && { printf '0'; return 0; } ;; esac
  _ts_int "${TRIAGE_STATE_CLIENT_NUDGE_S:-1209600}" 1209600 3600
}
# A defer-like verdict (queued / blocked: bin/triage-state.py DEFER_LIKE) comes
# back to the model after this even at TTL 0: it may wait on something no ref
# names (a harness code change).
ts_defer_ttl() { _ts_int "${TRIAGE_STATE_DEFER_TTL_S:-7200}" 7200 600; }
# BH-3920: a model-set ticket an rc-0 session left no evidence for is held off
# the model this long (bin/triage-state.py record, `handed-no-decision`).
ts_hnd_backoff() { _ts_int "${TRIAGE_STATE_HANDED_NO_DECISION_BACKOFF_S:-7200}" 7200 600; }
# BH-8497: a `triaged` verdict with no DECISION line goes back to the model this
# many times (one backoff apart), then is final with one ALERT line. Row
# lib.triage-state.<project>.triage_state_no_decision_retries; fallback 3, junk
# is 3, 0 = off (the verdict is final at once, as before).
ts_nd_retries() { _ts_int "${TRIAGE_STATE_NO_DECISION_RETRIES:-3}" 3 0; }
_ts_mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0; }

# _ts_refs_merge <refs-file> <number> <state> — ONE entry into refs.json. The
# file is shared by the tick's pre-check, the single session's recorder and
# every detached shard's recorder, which run concurrently: the update is made
# under an flock on <refs-file>.lock, re-reads the CURRENT file (never a copy
# taken earlier, so a concurrent writer's entries survive), writes a
# per-process temp and renames it in (a reader never sees a torn file).
_ts_refs_merge() {
  local f="$1" n="$2" st="$3" tmp
  tmp=$(mktemp "$f.XXXXXX" 2>/dev/null) || return 0
  (
    command -v flock >/dev/null 2>&1 && flock -w 10 8
    { jq -e 'type=="object"' "$f" >/dev/null 2>&1 && cat "$f" || echo '{}'; } \
      | jq --arg n "$n" --arg s "$st" '.[$n] = $s' > "$tmp" 2>/dev/null && [ -s "$tmp" ] && mv -f "$tmp" "$f"
  ) 8>>"$f.lock"
  rm -f "$tmp"
  return 0
}

# _ts_refs_keep <refs-file> <names-file> — drop the entries no open ticket names,
# with the same lock / re-read / per-process temp / rename as _ts_refs_merge.
_ts_refs_keep() {
  local f="$1" names="$2" tmp
  tmp=$(mktemp "$f.XXXXXX" 2>/dev/null) || return 0
  (
    command -v flock >/dev/null 2>&1 && flock -w 10 8
    jq --rawfile names "$names" '($names | split("\n") | map(select(length > 0))) as $k
      | with_entries(select(.key as $x | $k | index($x)))' "$f" > "$tmp" 2>/dev/null && [ -s "$tmp" ] && mv -f "$tmp" "$f"
  ) 8>>"$f.lock"
  rm -f "$tmp"
  return 0
}

# _ts_fetch_refs <numbers-file> — the bounded REST lookup of #N refs the board
# fingerprint cannot place, cached in refs.json (CLOSED / MERGED / MISSING are
# final, OPEN is re-asked). Runs in the caller's scope: reads $d $refs $max
# $slug, spends $nf against the per-tick fetch cap, sets fetched=1 on a write.
# Each REST body lands in a per-process temp: a fixed name shared with a
# concurrent shard would let one ref's body be read as another's, and a wrong
# CLOSED / MERGED is final. With _TS_FETCH_LOG set, every "<n> <state>" looked
# up is also appended there.
_ts_fetch_refs() {
  local n st body
  for n in $(cat "$1" 2>/dev/null); do
    [ "$nf" -lt "$max" ] && [ -n "$slug" ] && command -v gh_rest >/dev/null 2>&1 || break
    case "$(jq -r --arg n "$n" '.[$n] // ""' "$refs" 2>/dev/null)" in CLOSED|MERGED|MISSING) continue ;; esac
    nf=$((nf+1)); st=""
    body=$(mktemp "$d/ref.XXXXXX" 2>/dev/null) || break
    gh_rest GET "repos/$slug/issues/$n" > "$body" 2>/dev/null
    case $? in   # the REST contract: 0 body, 44 absent, 75 no answer (bin/lib/gh-rest.sh)
      0) st=$(jq -r 'if (.pull_request.merged_at // null) != null then "MERGED" else ((.state // "") | ascii_upcase) end' "$body" 2>/dev/null) ;;
      44) st=MISSING ;;
    esac
    rm -f "$body"
    case "$st" in OPEN|CLOSED|MERGED|MISSING)
      _ts_refs_merge "$refs" "$n" "$st"; fetched=1
      [ -n "${_TS_FETCH_LOG:-}" ] && printf '%s %s\n' "$n" "$st" >> "$_TS_FETCH_LOG" ;;
    esac
  done
  return 0
}

_ts_gh_budget_low() {
  local h; h=$(_ts_h)
  [ -r "$h/bin/lib/gh-budget.sh" ] && ( . "$h/bin/lib/gh-budget.sh" 2>/dev/null; gh_budget_low triage-state ) >/dev/null 2>&1
}

_ts_dir() { [ -n "$(_ts_h)" ] || return 0; printf '%s/state/triage-state/%s' "$(_ts_h)" "${1:-${PROJECT:-}}"; }

# _ts_prefix <project> — the board's key prefix (TS in TK-<issue-number>), from
# prompts/<project>.md exactly as bin/lib/preplan-lib.sh reads it. Empty in-app.
_ts_prefix() {
  local h; h=$(_ts_h)
  [ -n "$h" ] || return 0
  grep -ohE '\b[A-Z]{1,6}-<issue-number>' "$h/prompts/$1.md" 2>/dev/null | head -1 | cut -d- -f1
}

# _ts_canon_wake — the keys a webhook named this tick (EW_KEYS, set by the scope
# stage), in the canonical form the entries use, space-padded for a case match.
_ts_canon_wake() {
  local k out=" "
  for k in ${EW_KEYS:-}; do
    k="${k#\#}"
    case "$k" in [A-Za-z]*-[0-9]*) [ "$1" = 1 ] && k="${k##*-}" ;; esac
    out="$out$k "
  done
  printf '%s' "$out"
}

# ts_hash_of <key> — the input hash this tick's pre-check computed for a key.
# _ts_snap_file <src> <dst> — an atomic copy (per-process temp, rename)
_ts_snap_file() {
  local tmp
  tmp=$(mktemp "$2.XXXXXX" 2>/dev/null) || return 0
  cp -f "$1" "$tmp" 2>/dev/null && mv -f "$tmp" "$2" || rm -f "$tmp"
}

# _ts_refs_init <refs-file> — a missing or unreadable refs.json becomes {} by
# rename, never by truncating a file a concurrent writer is renaming into.
_ts_refs_init() {
  local tmp
  jq -e 'type=="object"' "$1" >/dev/null 2>&1 && return 0
  tmp=$(mktemp "$1.XXXXXX" 2>/dev/null) || return 0
  echo '{}' > "$tmp" && mv -f "$tmp" "$1"
}

# ts_shard_hash <key> — ts_hash_of, plus the shard's SNAPSHOT of what that hash
# was computed from: this tick's board fingerprint, refs.json and the key's
# decisions.tsv line (its base). A shard is detached and records after the
# NEXT tick's pre-check may have rewritten world.json / refs.json /
# decisions.tsv; stamping against those would bake a later state (a ref that
# merged meanwhile) into the verdict hash and the ticket would never be
# re-offered. ts_after_session reads only this snapshot for a shard.
#
# Prints <hash>.<nonce>: every dispatch gets its OWN snapshot directory
# (mktemp -d), so a second dispatch of the same key and hash never overwrites
# the snapshot a running shard will record against. The shard hands the whole
# value back to ts_after_session, which splits it. No snapshot could be made:
# the bare hash (ts_after_session then stamps it as handed).
ts_shard_hash() {
  local k="${1:-}" hv d snap
  hv=$(ts_hash_of "$k")
  [ -n "$hv" ] || return 0
  d=$(_ts_dir)
  mkdir -p "$d/snap" 2>/dev/null
  if snap=$(mktemp -d "$d/snap/$k.$hv.XXXXXX" 2>/dev/null); then
    cp -f "$d/world.json" "$snap/world.json" 2>/dev/null
    cp -f "$d/refs.tick.json" "$snap/refs.json" 2>/dev/null || cp -f "$d/refs.json" "$snap/refs.json" 2>/dev/null \
      || echo '{}' > "$snap/refs.json"
    # the key's own pre-session row: a hand-off keeps its previous reason
    jq -c --arg k "$k" '[.[]? | select((.ticket_key // "" | tostring) == $k)]' "$d/rows.json" > "$snap/rows.json" 2>/dev/null \
      || rm -f "$snap/rows.json"
    awk -F'\t' -v k="$k" '$1==k' "$d/$(_ts_dec_file "$k")" > "$snap/decisions.tsv" 2>/dev/null
    printf '%s.%s' "$hv" "${snap##*.}"
  else
    printf '%s' "$hv"
  fi
}

ts_hash_of() {
  [ -n "$(_ts_h)" ] || return 0
  awk -F'\t' -v k="${1:-}" '$1==k && $5!="-" {print $5; exit}' "$(_ts_dir)/$(_ts_dec_file "${1:-}")" 2>/dev/null
}

# _ts_dec_file <key> — the pre-check file that holds a key's decisions line: a
# PR shard's (pr-<n>) is pr-decisions.tsv (the BH-3417 contract, same columns),
# everything else decisions.tsv. A shard's snapshot keeps the line as
# decisions.tsv either way, so ts_after_session reads both kinds alike.
_ts_dec_file() { case "${1:-}" in pr-*) printf 'pr-decisions.tsv' ;; *) printf 'decisions.tsv' ;; esac; }

# _ts_owned <key> <label> <hash> <triaged_at> <gh> — rc 0 and the reason on
# stdout when a `buildable` ticket must NOT be launched now; rc 1 when nothing
# owns it. Every read that cannot answer owns it (fail CLOSED for a launch).
_ts_owned() {
  local key="$1" label="$2" hash="$3" tat="$4" gh="$5" h d p lc st rc n raw hv
  h=$(_ts_h); d=$(_ts_dir); p="$PROJECT"
  [ -n "$h" ] || { printf 'owned:no-root'; return 0; }
  [ "$(cat "$d/$key.enqueued" 2>/dev/null)" = "$hash" ] && { printf 'owned:enqueued'; return 0; }
  if [ -e "$h/locks/build-key-$p-$label.lock" ] \
     && ! ( exec 7>"$h/locks/build-key-$p-$label.lock" && flock -n 7 ) 2>/dev/null; then
    printf 'owned:building'; return 0
  fi
  if [ -n "$tat" ]; then
    [ -n "$(find "$h/builds" -maxdepth 1 \( -name "$p-$label-*" -o -name "pool-$p-$label-*" \) -newermt "$tat" 2>/dev/null | head -1)" ] \
      && { printf 'owned:build-dir'; return 0; }
  fi
  if command -v job_ledger_get >/dev/null 2>&1; then
    st=$(job_ledger_get abandoned "$p $label" 2>/dev/null) && [ "$st" = abandoned ] && { printf 'owned:abandoned'; return 0; }
  fi
  if command -v queue_status >/dev/null 2>&1; then
    st=$(queue_status "$p" "$label" 2>/dev/null); rc=$?
    case "$rc" in
      0) case "$st" in queued|claimed|running|ready) printf 'owned:queue-%s' "$st"; return 0 ;; esac ;;
      2) ;;
      *) printf 'owned:queue-unreadable'; return 0 ;;
    esac
  fi
  _ts_prs_json "$p" "$d"
  [ "$(head -c 10 "$d/prs.json")" = unreadable ] && { printf 'owned:pr-unreadable'; return 0; }
  lc=$(printf '%s' "$label" | tr '[:upper:]' '[:lower:]')
  n=$(jq -r --arg lc "$lc" --arg l "$label" \
    '[.[] | select(((.head.ref // "") | ascii_downcase | contains($lc)) or ((.title // "") | startswith($l)))] | .[0].number // empty' \
    "$d/prs.json" 2>/dev/null)
  [ -n "$n" ] && { printf 'owned:pr-%s' "$n"; return 0; }
  if [ "$gh" = 1 ]; then
    raw="$d/$key.raw"
    if command -v hold_classify >/dev/null 2>&1 && [ -s "$raw" ]; then
      hv=$(hold_classify "$(jq -c '.doc.issue' "$raw" 2>/dev/null)" "$(jq -c '.doc.comments' "$raw" 2>/dev/null)"); rc=$?
      # A ticket waiting on a human step says so (BH-3443), in the words every
      # lane uses: `skip :: waiting on human: <action>`.
      case "$hv" in *"	hold:waiting-on-human "*)
        _ts_log "triage-state: $label skip :: waiting on human: $(printf '%s' "${hv#*hold:waiting-on-human }" | cut -d' ' -f2-)" ;;
      esac
      [ "$rc" = 0 ] || { printf 'held:%s' "$(printf '%s' "$hv" | tr '\t\n' '  ' | cut -c1-120)"; return 0; }
    else
      printf 'held:unreadable'; return 0
    fi
  else
    # FAIL CLOSED: --buildable-strict answers BLOCKED on a read it could not
    # make, and anything that is not a plain OK (no answer, a RUN line from an
    # unknown project) holds the launch too.
    hv=$("$h/bin/triage-gate.sh" "$p" --buildable-strict "$key" 2>/dev/null </dev/null) || hv="BLOCKED unreadable"
    case "$hv" in
      OK) ;;
      BLOCKED*) printf 'held:%s' "${hv#BLOCKED }"; return 0 ;;
      *) printf 'held:unreadable'; return 0 ;;
    esac
  fi
  if command -v pause_active >/dev/null 2>&1 && pause_active "$p" builds 2>/dev/null; then
    printf 'owned:builds-paused'; return 0
  fi
  # The overlap guard writes its own lane-log lines and cache, so shadow does
  # not run it: a shadow "would enqueue" is before the launch-time overlap check.
  if [ "${TS_MODE:-}" = enforce ] && [ -x "$h/bin/overlap-guard.sh" ]; then
    hv=$("$h/bin/overlap-guard.sh" "$p" "$label" 2>/dev/null </dev/null)
    case "$hv" in DEFER*) printf 'owned:overlap'; return 0 ;; esac
  fi
  return 1
}

# _ts_human_step <dir> <key> <label> — BH-6536, GitHub boards only. rc 0 sets
# _TS_HS to `human-step:<state>` when the ticket waits on, or has, a person's
# HUMAN-STEP-DONE: answer to a human-step REVIEW_BLOCKED build. Both branches
# need the label's NEWEST record to be that REVIEW_BLOCKED record, not
# superseded or abandoned by bin/blocked-resolver.sh: any newer record (a
# rebuild's PLAN_BLOCKED, say) means the flow ended and the decision stands
# (BH-6536 review B2). Then (a) its ticket_stage row is newer than that record,
# or (b) a person answered after it (`done-unclaimed`, which also writes the
# stage row, lane triage). For (b), a local review.md that is not a human-step
# BLOCK (nh_sd_human_only rc 1) is not this flow; with no readable review.md
# the reason says only what is known. The gate is local (the cached thread has
# such a comment); only then one ledger read and one bor_union per tick
# ($d/bor.tsv). Any read that fails is rc 1: the decision stands.
_ts_human_step() {
  local d="$1" key="$2" label="$3" h p raw pf row rc st sat nt="" nr="" nd="" res dir ev who at rd="" hrc=2 why
  h=$(_ts_h); p="${PROJECT:-}"; raw="$d/$key.raw"; _TS_HS=""
  case "$key" in ''|*[!0-9]*) return 1 ;; esac
  pf="${NH_DONE_PREFIX:-HUMAN-STEP-DONE:}"
  jq -e --arg pf "$pf" '[.doc.comments[]? | (.body // "") | tostring | gsub("\r"; "") | split("\n")
      | map(sub("^[ \t]+"; "")) | map(select(length > 0)) | (first // "") | startswith($pf)] | any' "$raw" >/dev/null 2>&1 || return 1
  # shellcheck source=bin/lib/needs-human.sh
  declare -F nh_sd_done_after >/dev/null 2>&1 || { [ -r "$h/bin/lib/needs-human.sh" ] && . "$h/bin/lib/needs-human.sh" 2>/dev/null; }
  # shellcheck source=bin/lib/builds-of-record.sh
  declare -F bor_union >/dev/null 2>&1 || { [ -r "$h/bin/lib/builds-of-record.sh" ] && . "$h/bin/lib/builds-of-record.sh" 2>/dev/null; }
  declare -F nh_sd_done_after nh_sd_stage_put bor_union job_ledger_row >/dev/null 2>&1 || return 1
  row=$(job_ledger_row ticket_stage "$p#$key" 2>/dev/null); rc=$?
  [ "$rc" = 1 ] && return 1
  [ -e "$d/bor.tsv" ] || { bor_union "$p" 2>/dev/null; echo "#rc=$?"; } > "$d/bor.tsv"
  grep -qx '#rc=1' "$d/bor.tsv" && return 1
  # the label's newest record (epoch, result, dir)
  while IFS=$'\t' read -r at res dir; do
    [ -n "$at" ] || continue
    at=$(date -u -d "$at" +%s 2>/dev/null) || continue
    [ "$at" -gt "${nt:-0}" ] && { nt=$at; nr=$res; nd=$dir; }
  done < <(awk -F'\t' -v k="$label" '$1==k {print $4 "\t" $5 "\t" $2}' "$d/bor.tsv")
  case "${nr:-}" in REVIEW_BLOCKED*) ;; *) return 1 ;; esac
  for dir in "$h/builds/$nd" "$h/builds/pool-$nd" "$h/builds/fly-$nd"; do
    [ -n "$nd" ] && [ -d "$dir" ] || continue
    [ -e "$dir/.blocked-resolver-superseded" ] || [ -e "$dir/.blocked-resolver-abandoned" ] && return 1
    [ -n "$rd" ] || rd=$dir
  done
  if [ -n "$row" ]; then
    st=$(printf '%s' "$row" | jq -r '.detail' 2>/dev/null | awk '{print $1}')
    sat=$(printf '%s' "$row" | jq -r '.detail' 2>/dev/null | sed -nE 's/^[^ ]+ by [^ ]+ at ([^ ]+): .*/\1/p')
    if [ -n "$sat" ]; then sat=$(date -u -d "$sat" +%s 2>/dev/null) || sat=0; else sat=0; fi
    case " $NH_SD_STATES " in *" $st "*) [ "$sat" -gt "$nt" ] && { _TS_HS="human-step:$st"; return 0; } ;; esac
  fi
  if [ -n "$rd" ] && [ -r "$rd/review.md" ]; then
    nh_sd_human_only "$rd/review.md" >/dev/null 2>&1; hrc=$?
    [ "$hrc" = 1 ] && return 1
  fi
  ev=$(nh_sd_done_after "$(jq -c '.doc.comments' "$raw" 2>/dev/null)" "$(_ts_iso "$nt")") || return 1
  who=$(printf '%s\n' "$ev" | sed -nE 's/^author: (@[^ ]*) at (.*)$/\1/p'); at=$(printf '%s\n' "$ev" | sed -nE 's/^author: @[^ ]* at (.*)$/\1/p')
  if [ "$hrc" = 0 ]; then why="bin/review-rescue.sh checks build $nd from $(_ts_iso $((nt + 5400)))"
  else why="this box cannot read the review of build $nd; the rescue lane decides from $(_ts_iso $((nt + 5400)))"; fi
  AGENT_CALL_LANE=triage nh_sd_stage_put "$p" "$key" "$label" human-step-done \
    "$who posted HUMAN-STEP-DONE at $at; $why" >/dev/null 2>&1
  _TS_HS="human-step:done-unclaimed"
  return 0
}

# ts_precheck — the deterministic pass. Reads HARNESS/PROJECT (and EW_KEYS,
# STAMP, LOG from the tick). Writes state/triage-state/<p>/decisions.tsv
# (key, label, decision, reason, input_hash, seed), one observe row per open
# ticket, and one lane-log line. Sets TS_MODE, TS_READY (1 when every
# decision was made), TS_LLM (labels), TS_SKIPSET (" key key "), TS_ENQ
# (key<TAB>label lines). Always rc 0.
ts_precheck() {
  local h p d world py gh=0 pfx km ttl now max nofetch=0 nf=0 wake key label esha op seed need f
  local rows_ok=1 dec reason hash rest n_open=0 n_llm=0 n_skip=0 rowsf lh tat slug refs fetched scope isc work wk
  local base note dttl restamped="" stamped="" readset needset n_cap=0 n_bud=0 tier ep dwhy=cap mr="" mk mn mt
  h=$(_ts_h); p="${PROJECT:-}"
  TS_MODE=off; TS_READY=0; TS_ROWS_OK=0; TS_LLM=""; TS_SKIPSET=" "; TS_ENQ=""; TS_LLM_KEYS=""; export TS_ROWS_OK
  [ -n "$p" ] && [ -n "$h" ] || return 0
  d=$(_ts_dir "$p")
  rm -f "$d/decisions.tsv" "$d/prs.json" "$d/pr-decisions.tsv" "$d/bor.tsv" 2>/dev/null
  _ts_knobs "$p"
  TS_MODE=$(ts_mode "$h" "$p")
  [ "$TS_MODE" = off ] && return 0
  mkdir -p "$d" 2>/dev/null || return 0
  py="$h/bin/triage-state.py"
  command -v jq >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1 && [ -r "$py" ] || return 0
  world="$h/state/$p.gate.pending"; [ -s "$world" ] || world="$h/state/$p.gate.json"
  if [ ! -s "$world" ] || ! jq -e 'type=="object"' "$world" >/dev/null 2>&1; then
    _ts_log "triage-state $TS_MODE: no board fingerprint on this box yet — nothing decided, the tick runs as before"
    return 0
  fi
  cp -f "$world" "$d/world.json" 2>/dev/null || return 0
  jq -e 'has("issues")' "$d/world.json" >/dev/null 2>&1 && gh=1
  pfx=""; [ "$gh" = 1 ] && pfx=$(_ts_prefix "$p")
  km="$h/state/$p.keymap.json"
  PYTHONDONTWRITEBYTECODE=1 python3 "$py" entries --world "$d/world.json" --prefix "$pfx" --keymap "$km" \
    > "$d/entries.tsv" 2>/dev/null || { _ts_log "triage-state $TS_MODE: could not read the board fingerprint — nothing decided"; return 0; }
  ttl=$(ts_ttl); now=$(_ts_now)
  max=$(_ts_int "${TRIAGE_STATE_MAX_FETCH:-30}" 30 0)
  wake=$(_ts_canon_wake "$gh")
  if [ "$gh" = 1 ] && _ts_gh_budget_low; then
    nofetch=1
  fi
  # The rows, one read. An unreachable worker: every ticket to the model.
  rowsf="$d/rows.json"
  if ! { command -v triage_state_list >/dev/null 2>&1 && triage_state_list "$p" > "$rowsf" 2>/dev/null \
         && jq -e 'type=="array"' "$rowsf" >/dev/null 2>&1; }; then
    echo null > "$rowsf"; rows_ok=0
  fi
  TS_ROWS_OK=$rows_ok
  dttl=$(ts_defer_ttl)
  # The threads: read only what moved (BH-3921). A key with a cached thread
  # whose entry stamp is this tick's board entry is hashed from the cache,
  # whatever a webhook named or a recheck says: the recheck is the model's,
  # and the session reads the thread itself.
  # PASS 1 (BH-3920): every open key that needs a read, as <tier> <last tried>
  # <key>. Tier 0 is a key a webhook named this tick. The epoch is the last read
  # ATTEMPT (.tried, touched on success and failure alike, so a thread that
  # always fails rotates like any other), else the cached thread's mtime, else
  # 0 (never read). The first $max after a stable sort are this tick's reads,
  # so the same head of the board can never spend the whole cap every tick.
  : > "$d/need.tsv"
  while IFS=$'\t' read -r -u 3 key label esha op seed; do
    [ "$op" = 1 ] || continue
    [ -s "$d/$key.raw" ] && [ "$(cat "$d/$key.entry" 2>/dev/null)" = "$esha" ] && continue
    tier=1; case "$wake" in *" $key "*) tier=0 ;; esac
    if [ -e "$d/$key.tried" ]; then ep=$(_ts_mtime "$d/$key.tried")
    elif [ -e "$d/$key.raw" ]; then ep=$(_ts_mtime "$d/$key.raw")
    else ep=0; fi
    printf '%s\t%s\t%s\n' "$tier" "$ep" "$key" >> "$d/need.tsv"
  done 3< "$d/entries.tsv"
  readset=" "
  [ "$nofetch" = 0 ] && [ "$max" -gt 0 ] \
    && readset=" $(sort -s -t "$(printf '\t')" -k1,1n -k2,2n "$d/need.tsv" | head -n "$max" | cut -f3 | tr '\n' ' ')"
  # PASS 2: read the read set. A key that needs a read and is not in it keeps
  # its cached thread AND its entry stamp (so it stays owed): it is listed in
  # deferred.tick, hashed from the stale thread when there is one, and decided
  # `skip deferred:cap|budget` (bin/triage-state.py decide --deferred), never
  # `unhashable`, never unchanged and never the model's.
  : > "$d/batch.tsv"; : > "$d/deferred.tick"
  needset=" $(cut -f3 "$d/need.tsv" | tr '\n' ' ')"
  while IFS=$'\t' read -r -u 3 key label esha op seed; do
    [ "$op" = 1 ] || continue
    n_open=$((n_open+1))
    need=0
    case "$needset" in *" $key "*) need=1 ;; esac
    if [ "$need" = 1 ]; then
      case "$readset" in
        *" $key "*)
          rm -f "$d/$key.entry"; touch "$d/$key.tried"
          nf=$((nf+1))
          if "$h/bin/triage-gate.sh" "$p" --thread "$key" > "$d/$key.raw.t" 2>/dev/null </dev/null && [ -s "$d/$key.raw.t" ]; then
            mv -f "$d/$key.raw.t" "$d/$key.raw"; printf '%s' "$esha" > "$d/$key.entry"
          else
            rm -f "$d/$key.raw.t" "$d/$key.raw"
          fi ;;
        *) printf '%s\n' "$key" >> "$d/deferred.tick"
           [ -s "$d/$key.raw" ] && printf '%s\t%s\n' "$key" "$d/$key.raw" >> "$d/batch.tsv"
           continue ;;
      esac
    fi
    [ -s "$d/$key.raw" ] && [ -e "$d/$key.entry" ] && printf '%s\t%s\n' "$key" "$d/$key.raw" >> "$d/batch.tsv"
  done 3< "$d/entries.tsv"
  # A ticket that left the open set takes its cache with it (the thread, its
  # entry stamp, its last read attempt and any launch marker), so the directory
  # is bounded by the board.
  for f in "$d"/*.raw "$d"/*.entry "$d"/*.tried "$d"/*.enqueued; do
    [ -e "$f" ] || continue
    key=$(basename "$f"); key="${key%.*}"
    awk -F'\t' -v k="$key" '$1==k && $4=="1" {f=1} END {exit !f}' "$d/entries.tsv" || rm -f "$f"
  done
  refs="$d/refs.json"; _ts_refs_init "$refs"
  # shard snapshots (ts_shard_hash) a shard never came back for
  [ -d "$d/snap" ] && find "$d/snap" -mindepth 1 -maxdepth 1 -mmin +1440 -exec rm -rf {} + 2>/dev/null
  # and the per-process temps a killed writer left behind (never refs.json,
  # refs.json.lock or refs.tick.json: the patterns are the mktemp names only)
  find "$d" -maxdepth 1 -type f -mmin +1440 \( -name 'refs.priv.??????' -o -name 'refs.priv.??????.lock' \
    -o -name 'refs.json.??????' -o -name 'refs.fetched.??????' -o -name 'refs.fetched.??????.n' \
    -o -name 'ref.??????' -o -name 'refs.tick.json.??????' \) -exec rm -f {} + 2>/dev/null
  # MERGED REASON REFS (BH-3829, in-app only): a verdict that waited on KEY-N
  # (a PLAN_BLOCKED defer, "build after TK-2185 lands") names a ticket whose
  # board status does not move when its PR merges. bin/lib/gate-release.sh's
  # gr_key_merged answers "merged, and when" from this box's build records, the
  # merge ledger, then one capped REST read; bin/triage-state.py suffixes the
  # ref `|merged` when that is later than the row's triaged_at, so the hash
  # moves once. DARK with lib.gate-release.GATE_RELEASE_MAX_LAUNCHES at 0 (its
  # default) or the gate-release-off switch: no file, no flag, today's hash.
  # At most GATE_RELEASE_MAX_LOOKUPS keys, in row order; a key past the cap is
  # not in the map, which is the hash this tick had before.
  if [ "$gh" = 0 ] && [ "$rows_ok" = 1 ]; then
    if ! declare -F gr_key_merged >/dev/null 2>&1 && [ -r "$h/bin/lib/gate-release.sh" ]; then
      # shellcheck source=bin/lib/gate-release.sh
      . "$h/bin/lib/gate-release.sh" 2>/dev/null
    fi
    if declare -F gr_key_merged >/dev/null 2>&1 && _gr_knobs && [ "$_GR_MAXLAUNCH" -gt 0 ] 2>/dev/null \
       && ! { declare -F lane_switch >/dev/null 2>&1 && HARNESS="$h" lane_switch gate-release-off file; }; then
      : > "$d/merged-refs.tsv"
      for mk in $(jq -r '.[]? | select(type=="object" and .verdict_hash) | .reason // ""' "$rowsf" 2>/dev/null \
                  | grep -oE '\b[A-Z][A-Z0-9]{0,9}-[0-9]+(\.[0-9]+)?\b' | grep -v '\.' | awk '!s[$0]++' \
                  | head -n "$_GR_MAXL" || true); do
        # in THIS shell, so the lookup cap spans the pass (gate-release/queue.sh)
        gr_key_merged "$h" "$p" "$mk" > "$d/merged-refs.one" 2>/dev/null || continue
        IFS=$'\t' read -r mn mt < "$d/merged-refs.one" || continue
        case "$mt" in ''|*[!0-9]*) continue ;; esac
        printf '%s\t%s\t%s\n' "$mk" "$mn" "$mt" >> "$d/merged-refs.tsv"
      done
      rm -f "$d/merged-refs.one"
      jq -Rn '[inputs | split("\t") | {key: .[0], value: [.[1], (.[2] | tonumber)]}] | from_entries' \
        < "$d/merged-refs.tsv" > "$d/merged-refs.json" 2>/dev/null && mr="$d/merged-refs.json"
      rm -f "$d/merged-refs.tsv"
    fi
  fi
  [ -n "$mr" ] || rm -f "$d/merged-refs.json"
  _ts_hash_batch() {
    : > "$d/hashed.tsv"
    [ -s "$d/batch.tsv" ] && TRIAGE_STATE_SELF_LABELS="${TRIAGE_STATE_SELF_LABELS:-}" PYTHONDONTWRITEBYTECODE=1 \
      python3 "$py" hash --world "$d/world.json" --prefix "$pfx" --refs "$refs" --rows "$rowsf" --batch "$d/batch.tsv" \
        ${mr:+--merged-refs "$mr"} > "$d/hashed.tsv" 2>/dev/null
  }
  _ts_hash_batch
  # A #N the board fingerprint cannot place (a blocker without the ai-build
  # label, an old PR) is looked up by REST, inside the same fetch cap, and its
  # state cached in refs.json. CLOSED / MERGED / MISSING (404) are final; an
  # OPEN one is re-asked each tick while the cap allows and some open ticket
  # still names it, so its closing moves the hash of every ticket that does.
  if [ "$gh" = 1 ] && [ "$nofetch" = 0 ]; then
    slug="${TRIAGE_GH_SLUG:-}"; [ -n "$slug" ] || slug=$("$h/bin/fleet-conf.sh" "$p" repo 2>/dev/null)
    fetched=0
    # Only the refs the tickets hashed THIS tick still name; an entry no open
    # ticket names is dropped, so a quiet board re-asks nothing.
    cut -f4 "$d/hashed.tsv" | tr ',' '\n' | grep -E '^[0-9]+$' | sort -un > "$d/refs.named"
    _ts_refs_keep "$refs" "$d/refs.named"
    _ts_fetch_refs "$d/refs.named"
    [ "$fetched" = 1 ] && _ts_hash_batch
  fi
  # The refs as THIS pre-check hashed against: the single session stamps
  # against this copy, never refs.json as a concurrent shard left it later.
  _ts_snap_file "$refs" "$d/refs.tick.json"
  # Every entry, open or closed: a CLOSED ticket we hold a verdict for is the
  # decision pass's `llm closed`.
  # hashes.tsv: key label hash lua open seed base reason-deps (hashed.tsv
  # columns 5-6: the thread-only base hash and the stored reason's ref states)
  awk -F'\t' 'NR==FNR {hh[$1]=$2; lh[$1]=$3; bh[$1]=$5; rd[$1]=$6; next}
    {printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", $1, $2, ($1 in hh ? hh[$1] : "-"), ($1 in lh ? lh[$1] : "-"), $4, $5,
       (($1 in bh) && bh[$1] != "" ? bh[$1] : "-"), (($1 in rd) && rd[$1] != "" ? rd[$1] : "-")}' \
    "$d/hashed.tsv" "$d/entries.tsv" > "$d/hashes.tsv"
  [ "$nofetch" = 1 ] && dwhy=budget
  PYTHONDONTWRITEBYTECODE=1 python3 "$py" decide --hashes "$d/hashes.tsv" --rows "$rowsf" --now "$now" --ttl "$ttl" --defer-ttl "$dttl" --world "$d/world.json" \
    --decisions "$h/logs/decisions.log" --project "$p" --prefix "$pfx" --keymap "$km" --gh "$gh" --deferred "$d/deferred.tick" \
    --deferred-why "$dwhy" --nudge "$(ts_nudge)" --no-decision-retries "$(ts_nd_retries)" \
    > "$d/decided.tsv" 2>/dev/null || { _ts_log "triage-state $TS_MODE: the decision pass failed — nothing decided"; return 0; }
  # deferred.keys is the owed-read list bin/triage-gate.sh step 1d drains with
  # `RUN ts-deferred` ticks: rewritten whole by every enforce pre-check, and
  # left empty in any other mode (shadow never buys a tick for it).
  if [ "$TS_MODE" = enforce ]; then
    mv -f "$d/deferred.tick" "$d/deferred.keys" 2>/dev/null
  else
    : > "$d/deferred.keys"; rm -f "$d/deferred.tick"
  fi
  # IN SCOPE: what this tick actually puts in front of the model. A full tick
  # reads every open ticket; a scoped one reads its board lines, its queue
  # lines and its finished builds, and nothing else (ts_after_session only
  # blanket-stamps a ticket that was in scope).
  scope=all; [ "${SCOPE_N:-full}" = full ] || scope=" $(_ts_scope_keys) "
  # WORK: a key with a queue line or a finished build in this tick is the
  # session's to work (launch, defer, the close-out comment and status),
  # whatever its triage state. Decided here, once, as decisions.tsv column 9:
  # ts_tick's do-not-touch list and the shadow scorecard both read it. A work
  # key is the board label in-app (TK-2182) and the number on GitHub (13), so a
  # ticket matches by its key OR its label, whole tokens only.
  work=" $(_ts_work_keys | tr '\n' ' ') "
  # A `buildable` verdict whose inputs did not move: launch it, or name its owner.
  : > "$d/decisions.tsv"
  while IFS=$'\t' read -r -u 3 key label dec reason hash seed base note; do
    [ "$note" = restamp ] && restamped="$restamped $label"
    # BH-6536: a human-step REVIEW_BLOCKED ticket is never the model's nor a launch.
    [ "$gh" = 1 ] && [ "$dec" != stamp ] && _ts_human_step "$d" "$key" "$label" \
      && { dec=skip; reason=$_TS_HS; _ts_log "triage-state: $label skip :: human step: ${_TS_HS#human-step:}"; }
    if [ "$dec" = candidate ]; then
      tat=$(jq -r --arg k "$key" '.[]? | select(.ticket_key==$k) | .triaged_at // empty' "$rowsf" 2>/dev/null | head -1)
      if lh=$(_ts_owned "$key" "$label" "$hash" "$tat" "$gh"); then
        dec=skip; reason="buildable-$lh"   # buildable-owned:<what> | buildable-held:<why>
      else
        dec=enqueue; reason=buildable
      fi
    fi
    isc=1; [ "$scope" = all ] || case "$scope" in *" $key "*|*" $label "*) ;; *) isc=0 ;; esac
    wk=0; case "$work" in *" $key "*|*" $label "*) wk=1 ;; esac
    # decisions.tsv: key label decision reason hash seed in-scope base work
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$key" "$label" "$dec" "$reason" "$hash" "$seed" "$isc" "${base:--}" "$wk" >> "$d/decisions.tsv"
  done 3< "$d/decided.tsv"
  # the summary
  while IFS=$'\t' read -r -u 3 key label dec reason hash seed isc; do
    case "$dec" in
      llm) n_llm=$((n_llm+1)); TS_LLM="$TS_LLM $label"; TS_LLM_KEYS="$TS_LLM_KEYS $key" ;;
      # a deferred key is carried, not unchanged: counted apart (cap= / budget=)
      skip) case "$reason" in
              deferred:cap) n_cap=$((n_cap+1)) ;;
              deferred:budget) n_bud=$((n_bud+1)) ;;
              *) n_skip=$((n_skip+1)) ;;
            esac
            TS_SKIPSET="$TS_SKIPSET$key " ;;
      stamp) stamped="$stamped $label"; TS_SKIPSET="$TS_SKIPSET$key " ;;
      enqueue) TS_SKIPSET="$TS_SKIPSET$key "; TS_ENQ="$TS_ENQ$key	$label
" ;;
    esac
  done 3< "$d/decisions.tsv"
  _ts_observe "$p" "$d/decisions.tsv"
  # THE REASON-REFS TRANSITION (one-time): a row stamped before reason refs
  # joined the hash, whose reason's refs are all still open, is re-stamped in
  # place by the observe write above — no model call. Logged so the cost of the
  # transition is visible: every re-stamp here is a ticket NOT re-triaged.
  # A ticket CLOSED on the board is stamped `closed` by the observe write above,
  # with no model call (bin/triage-state.py decide, `stamp closed-on-board`).
  [ -n "$stamped" ] && _ts_log "triage-state $TS_MODE: stamped $(printf '%s' "$stamped" | wc -w | tr -d ' ') closed ticket(s) without a model call:$(printf '%s' "$stamped" | cut -c1-600)"
  [ -n "$restamped" ] && _ts_log "triage-state $TS_MODE: re-stamped $(printf '%s' "$restamped" | wc -w | tr -d ' ') legacy verdict(s) with their reason refs, no model call:$(printf '%s' "$restamped" | cut -c1-600)"
  rest=""
  [ "$rows_ok" = 0 ] && rest=" (rows unreadable: every ticket to the model)"
  if [ "$TS_MODE" = shadow ]; then
    ts_waste_account unrestricted
    _ts_log "triage-state shadow: $n_open open, $n_llm to the model${TS_LLM:+:$TS_LLM}, $n_skip unchanged, $(printf '%s' "$TS_ENQ" | grep -c .) would enqueue$( [ -n "$TS_ENQ" ] && printf ': %s' "$(printf '%s' "$TS_ENQ" | cut -f2 | tr '\n' ' ' | sed 's/ $//')")$rest — shadow: the tick runs as before [gate=${GATE_REASON:-?} reads=$nf cap=$n_cap budget=$n_bud$(ts_waste_bracket)]"
  else
    TS_SUMMARY="$n_open open, $n_llm to the model${TS_LLM:+:$TS_LLM}, $n_skip unchanged$rest [reads=$nf cap=$n_cap budget=$n_bud]"
  fi
  # Decisions made without the rows are all `llm` — true, and useless: the tick
  # runs exactly as it did, with nothing to enforce.
  [ "$rows_ok" = 1 ] && TS_READY=1
  return 0
}

# _ts_observe <project> <decisions.tsv> — one batched write per 200 tickets:
# the hash each ticket was seen with, what was decided and under which mode,
# plus a seed verdict where the tick already knew one. Never a verdict of its
# own: that is ts_after_session's, from the session.
_ts_observe() {
  local p="$1" f="$2" d
  command -v triage_state_put >/dev/null 2>&1 || return 0
  d=$(_ts_dir "$p")
  jq -R -s --arg p "$p" --arg m "$TS_MODE" '
    [ split("\n")[] | select(length > 0) | split("\t")
      | {ticket_key: .[0], ticket_label: .[1], last_decision: (if .[2]=="enqueue" then "enqueue" else (.[2] + " " + .[3]) end),
         last_mode: $m}
        + (if .[4] != "-" then {input_hash: .[4]} else {} end)
        + (if (.[5] // "-") != "-" then (.[5] | fromjson) else {} end)
      | if (.ticket_label | test("^[A-Za-z0-9._#-]{1,64}$")) then . else del(.ticket_label) end ]
    | [ range(0; length; 200) as $i | {project: $p, rows: .[$i:$i+200]} ] | .[]' "$f" -c 2>/dev/null \
  | while IFS= read -r body; do
      printf '%s' "$body" > "$d/put.json" && triage_state_put "$d/put.json" >/dev/null 2>&1
    done
  return 0
}

# ts_unit_skip <units-file> <key> — rc 0 when the shard loop must NOT dispatch
# this key: enforce is live this tick, the pre-check decided skip or enqueue,
# and every unit the key has is a board unit (a queue line or a finished build
# is launch / close-out work, never triage, and is always dispatched).
# A pr-* key is decided by the PR pre-check alone (TS_PR_ENFORCING,
# TS_PR_SKIPSET), never by the ticket set.
ts_unit_skip() {
  case "${2:-}" in
    pr-*)
      [ "${TS_PR_ENFORCING:-0}" = 1 ] || return 1
      case "${TS_PR_SKIPSET:- }" in *" $2 "*) return 0 ;; esac
      return 1 ;;
  esac
  [ "${TS_ENFORCING:-0}" = 1 ] || return 1
  case "${TS_SKIPSET:- }" in *" ${2:-} "*) ;; *) return 1 ;; esac
  [ -s "${1:-}" ] && awk -F'\t' -v k="$2" '$1==k && $2!="board" {f=1} END {exit !f}' "$1" && return 1
  return 0
}

# ts_enqueue — enforce: hand each `enqueue` ticket to bin/run-build.sh, the
# launch path bin/orphan-reconcile.sh uses (it holds the build-key dedupe, the
# duplicate-work guard and the context gate). The marker is written BEFORE the
# launch and carries the verdict_hash, so one verdict launches at most once.
ts_enqueue() {
  local h d max n=0 key label
  h=$(_ts_h); d=$(_ts_dir)
  [ -n "$h" ] || return 0
  max=$(_ts_int "${TRIAGE_STATE_ENQUEUE_MAX:-3}" 3 0)
  TS_LAUNCHED=""
  while IFS=$'\t' read -r key label; do
    [ -n "$key" ] || continue
    [ "$n" -lt "$max" ] || { _ts_log "triage-state: $label left for the next tick (TRIAGE_STATE_ENQUEUE_MAX=$max)"; continue; }
    ts_hash_of "$key" > "$d/$key.enqueued" 2>/dev/null
    if command -v lock_spawn_unheld >/dev/null 2>&1; then
      lock_spawn_unheld setsid "$h/bin/run-build.sh" "$PROJECT" "$key" "$label" \
        > "$h/logs/$PROJECT.$(printf '%s' "$label" | tr '[:upper:]' '[:lower:]')-triage-state.out" 2>&1
    else
      ( exec 8>&- 9>&-; exec setsid "$h/bin/run-build.sh" "$PROJECT" "$key" "$label" ) \
        > "$h/logs/$PROJECT.$(printf '%s' "$label" | tr '[:upper:]' '[:lower:]')-triage-state.out" 2>&1 &
    fi
    n=$((n+1)); TS_LAUNCHED="$TS_LAUNCHED $label"
    _ts_log "triage-state: $label is buildable, unchanged since its verdict and unbuilt — launched run-build.sh with no model call"
  done <<<"$TS_ENQ"
}

# _ts_key_of <class> <line> — the canonical key of one scope line, placed with
# the shard dispatcher's own triage_shard_key (rc 1 when it cannot be placed).
_ts_key_of() {
  local h gh=0
  h=$(_ts_h)
  [ -n "$h" ] || return 1
  if ! command -v triage_shard_key >/dev/null 2>&1; then
    # shellcheck source=bin/lib/triage-shards-lib.sh
    [ -r "$h/bin/lib/triage-shards-lib.sh" ] && . "$h/bin/lib/triage-shards-lib.sh" 2>/dev/null
  fi
  command -v triage_shard_key >/dev/null 2>&1 || return 1
  jq -e 'has("issues")' "$(_ts_dir)/world.json" >/dev/null 2>&1 && gh=1
  triage_shard_key "$1" "${PROJECT:-}" "$gh" "${2#'[HOTFIX] '}" 2>/dev/null
}

# _ts_board_keys — the keys of this tick's board lines (TICK_SCOPE, BOARD_SEC
# minus its header), `?` for a line nobody can place. PR lines are not tickets.
_ts_board_keys() {
  local line k
  while IFS= read -r line; do
    line=${line#'[HOTFIX] '}
    case "$line" in ''|'(none)'|'board prs:'*) continue ;; esac
    k=$(_ts_key_of board "$line") || k='?'
    printf '%s\n' "$k"
  done <<<"${TICK_SCOPE:-}
$(printf '%s' "${BOARD_SEC:-}" | tail -n +2)"
}

# _ts_work_keys — the keys this tick has launch or close-out work for: its
# queue lines and queue dirs, its finished builds awaiting a close-out, and a
# PLAN_BLOCKED result re-offered by bin/lib/gate-release/reoffer.sh
# (`board gate: REOFFER <KEY> ...`, BH-3829).
_ts_work_keys() {
  local line
  while IFS= read -r line; do
    case "$line" in ''|'(none)') continue ;; esac
    _ts_key_of queue "$line"
  done <<<"${QLINES:-}
${QDIRS:-}"
  while IFS= read -r line; do
    case "$line" in ''|'(none)') continue ;; esac
    _ts_key_of result "$line"
  done <<<"${RDIRS:-}"
  while IFS= read -r line; do
    case "${line#'[HOTFIX] '}" in 'board gate: REOFFER '*) _ts_key_of board "$line" ;; esac
  done <<<"${TICK_SCOPE:-}
$(printf '%s' "${BOARD_SEC:-}" | tail -n +2)"
  return 0
}

# _ts_scope_keys — every key a scoped tick puts in front of the model.
_ts_scope_keys() { { _ts_board_keys; _ts_work_keys; } | grep -v '^?$' | sort -u | tr '\n' ' '; }

# _ts_scope_llm — the model-set keys this tick's board scope names, `?` for a
# line nobody can place (which reads as work).
_ts_scope_llm() {
  local k out=""
  for k in $(_ts_board_keys); do
    case "$k" in '?') out="$out ?" ;; *) case " $TS_LLM_KEYS " in *" $k "*) out="$out $k" ;; esac ;; esac
  done
  printf '%s' "$out"
}

# ts_tick — the rt_shards hook (bin/lib/rt/shards.sh, before the shard units
# are formed). Runs the pre-check; under enforce, on a tick whose reason is a
# board/queue/sweep reason, launches the unchanged buildable tickets, and then
# EITHER ends the tick at $0 (nothing to send, no queue line, no finished build,
# no launchable child, no PR line in scope) OR appends one directive to the
# single session's prompt and leaves TS_SKIPSET for the shard filter.
# A forced / gate-error / no-gate-state tick is observed, never skipped. A
# ts-deferred tick (bin/triage-gate.sh step 1d: deferred.keys holds owed
# reads) is enforced like a board one.
# no-gate-state and gate-fetch-failed stay observe-only here; the rows-unreadable
# hook (bin/lib/triage-state-unreadable.sh, BH-3925) acts on them itself.
# The PR pre-check (ts_pr_precheck, bin/lib/triage-state-pr.sh, BH-3417) runs
# right after the ticket one and sets TS_PR_ENFORCING on the same rule.
_ts_enforce_reason() {
  case "${GATE_REASON:-}" in
    board-changed|event-wake|daily-sweep|queue-pending|results-sweep|remote-results-pending|split-ready|gate-reoffer|inapp-deps-ready|ts-deferred) return 0 ;;
    *) return 1 ;;
  esac
}
# _ts_sum — TS_SUMMARY with ts_waste_bracket inside its closing bracket
# (TS_SUMMARY always ends "]").
_ts_sum() { printf '%s' "${TS_SUMMARY%]}$(ts_waste_bracket)]"; }
ts_tick() {
  TS_ENFORCING=0; TS_PR_ENFORCING=0
  ts_precheck
  # No root or a box mid-sync without the PR lib: these defaults stand.
  TS_PR_MODE=off; TS_PR_READY=0; TS_PR_SKIPSET=" "; TS_PR_DRAFTS=""
  command -v ts_pr_precheck >/dev/null 2>&1 && ts_pr_precheck "${PROJECT:-}"
  [ "$TS_PR_MODE" = enforce ] && [ "$TS_PR_READY" = 1 ] && _ts_enforce_reason && TS_PR_ENFORCING=1
  case "${GATE_REASON:-}" in forced|forced-env) ;; *) ts_rows_unreadable_tick && return 0 ;; esac
  [ "$TS_MODE" = enforce ] && [ "$TS_READY" = 1 ] || return 0
  _ts_enforce_reason || { ts_waste_account unrestricted; _ts_log "triage-state enforce: $(_ts_sum) — observe only on a '${GATE_REASON:-?}' tick"; return 0; }
  TS_ENFORCING=1
  ts_enqueue
  # BH-8475 starvation guard (bin/lib/triage-starve.sh): count the pass, fastpath a key listed too
  # long with no run, then put the oldest listed keys first in TICK_SCOPE, which is the order the
  # shard units are built in (bin/lib/rt/shards.sh is not edited, BH-3418 B1). No lib = as before.
  local _ts_ord
  if [ "${TS_ROWS_OK:-0}" = 1 ] && [ -r "$(_ts_h)/bin/lib/triage-starve.sh" ] \
     && . "$(_ts_h)/bin/lib/triage-starve.sh"; then
    tsv_pass "$(_ts_h)" "${PROJECT:-}" || true
    _ts_ord=$(printf '%s\n' "${TICK_SCOPE:-}" | tsv_order_scope "$(_ts_h)" "${PROJECT:-}") \
      && [ -n "${TICK_SCOPE:-}" ] && [ -n "$_ts_ord" ] && TICK_SCOPE=$_ts_ord
  fi
  # WHAT THIS TICK WOULD SEND. A full-SOP tick reads every open ticket, so its
  # model set is the whole TS_LLM. A scoped tick (a board diff, a webhook's
  # keys) reads only its scope, so only the model-set tickets IN that scope
  # count: a never-triaged ticket elsewhere is the next full tick's, and a
  # doorbell press must never be widened into the board. A scope line this
  # cannot place is read as work (fail-open: the session runs).
  local want="$TS_LLM_KEYS" can_end=1
  [ "${SCOPE_N:-full}" = full ] || want=$(_ts_scope_llm)
  # Never a $0 end for these two: rt_gate_consume would stamp the full-sweep
  # clock on a daily sweep that swept nothing, and a remote-results tick has
  # JSON to process that no board line names.
  case "${GATE_REASON:-}" in daily-sweep|remote-results-pending) can_end=0 ;; esac
  # A re-offered PLAN_BLOCKED result (BH-3829) is the tick's work even when no
  # model-set key is in scope: the session re-reads it and relaunches.
  case "${TICK_SCOPE:-}
${BOARD_SEC:-}" in *"board gate: REOFFER "*) can_end=0 ;; esac
  if [ "$can_end" = 1 ] && [ -z "$want" ] && [ -z "${QLINES:-}${QDIRS:-}${RDIRS:-}" ] \
     && ! grep -qE 'UNBLOCKED|STACKABLE|^board prs:' <<<"$(printf '%s\n%s\n' "${TICK_SCOPE:-}" "${BOARD_SEC:-}")"; then
    # A ts-deferred tick read only owed keys, never the board: its scope is not
    # full, so rt_gate_consume absorbs the fingerprint without stamping the
    # daily sweep's clock (state/<p>.gate-meta).
    [ "${GATE_REASON:-}" = ts-deferred ] && SCOPE_N=ts-deferred
    command -v rt_gate_consume >/dev/null 2>&1 && rt_gate_consume
    if [ -n "${JOB_ID:-}" ] && command -v job_update >/dev/null 2>&1; then
      [ -n "${JOB_BEAT:-}" ] && command -v job_beat_stop >/dev/null 2>&1 && job_beat_stop "$JOB_BEAT"
      job_update "$JOB_ID" stage=done status=done "meta=triage-state: 0 changed" >/dev/null 2>&1
    fi
    command -v LANE_TICK >/dev/null 2>&1 && LANE_TICK skip
    ts_waste_account zero
    _ts_log "rc=skip :: triage-state: 0 changed — $TS_SUMMARY${TS_LAUNCHED:+, launched:$TS_LAUNCHED}; no model call [gate=${GATE_REASON:-?}$(ts_waste_bracket)]"
    exit 0
  fi
  ts_waste_account restricted
  _ts_log "triage-state enforce: $(_ts_sum)${TS_LAUNCHED:+, launched:$TS_LAUNCHED}"
  # A full tick's single session is told to re-triage the whole list (BH-8475).
  [ "${SCOPE_N:-full}" = full ] && command -v tsv_ran_all >/dev/null 2>&1 && tsv_ran_all "$(_ts_h)" "${PROJECT:-}"
  local unchanged
  # A key with a queue line or a finished build in this tick is the session's
  # to work, whatever its triage state: it is never on the do-not-touch list.
  # The pre-check decided that once (decisions.tsv column 9, ts_precheck).
  unchanged=$(awk -F'\t' '$3!="llm" && $3!="stamp" && $9!="1" {printf "%s ", $2}' "$(_ts_dir)/decisions.tsv" 2>/dev/null | cut -c1-2000)
  local only=""
  [ "${SCOPE_N:-full}" = full ] && only=" Re-triage ONLY:${TS_LLM:- (none)}."
  PROMPT_TEXT="${PROMPT_TEXT:-}

TRIAGE STATE (deterministic — bin/lib/triage-state.sh): every open ticket's inputs (its thread minus our own comments, its labels, the state of what it depends on) were hashed and compared with the hash its last verdict was made against.$only These tickets are unchanged since their verdict and must NOT be re-triaged this tick — do not fetch their threads, comment on them or change their status: ${unchanged:-(none)}. Queue lines and finished-build close-outs in this tick's scope are still yours to work."
  return 0
}

# ts_after_session <harness> <project> <rc> <session-out> [key] [hash] — record
# the session's verdicts, each stamped with the hash the pre-check computed
# BEFORE the session (a comment landing mid-session moves the hash again next
# tick). The single session (no key) reads this tick's decisions.tsv; a shard
# passes its own key and the hash it was handed. rc != 0 records nothing.
# _ts_record_run — bin/triage-state.py record, in ts_after_session's scope:
# against $W / $DEC / $ROWS (the tick's files, or a shard's snapshot) and $priv
# (a private copy of refs.json: the refs' PRE-session states).
_ts_record_run() {
  PYTHONDONTWRITEBYTECODE=1 python3 "$h/bin/triage-state.py" record --project "$p" --out "$out" --rc "$rc" \
    --now "$(_ts_now)" --ttl "$(ts_ttl)" --defer-ttl "$(ts_defer_ttl)" --decisions "$DEC" --key "$key" --hash "$hash" \
    --world "$W" --refs "$priv" --rows "$ROWS" --hnd-backoff "$(ts_hnd_backoff)" --nudge "$(ts_nudge)" \
    --no-decision-retries "$(ts_nd_retries)" --nd-backoff "$(ts_hnd_backoff)" \
    --prefix "${pfx:-}" --keymap "$h/state/$p.keymap.json" --gh "$gh" > "$d/record.$$.json" 2>/dev/null
}

# _ts_miss_snapshot <dir> <record.json> — shadow only, in ts_after_session's
# scope ($W, $DEC): per miss, the inputs the pre-check hashed for that ticket,
# in misses/<UTC stamp>-<label>/ — world-row.json (its row of the board
# fingerprint), thread.raw (the thread it hashed) and decision.tsv (its
# decisions line). Diagnostic only: nothing decides from it, a failed copy is
# ignored, and only the newest 50 are kept.
_ts_miss_snapshot() {
  local d="$1" rec="$2" k label at dir n
  at=$(date -u +%Y%m%dT%H%M%SZ)
  while IFS=$'\t' read -r k label; do
    [ -n "$k" ] || continue
    dir="$d/misses/$at-$(printf '%s' "${label:-$k}" | tr -c 'A-Za-z0-9._#-' '_')"
    mkdir -p "$dir" 2>/dev/null || continue
    [ -n "$W" ] && jq --arg k "$k" 'if has("issues") then [.issues[]? | select(type=="object" and ((.number // "") | tostring) == $k)]
        else [to_entries[] | select(.key != "meta" and (.value | type) == "array") | .value[]
              | select(type=="object" and ((.id // "") | tostring) == $k)] end | first // empty' "$W" > "$dir/world-row.json" 2>/dev/null
    [ -s "$d/$k.raw" ] && cp -f "$d/$k.raw" "$dir/thread.raw" 2>/dev/null
    [ -n "$DEC" ] && awk -F'\t' -v k="$k" '$1==k' "$DEC" > "$dir/decision.tsv" 2>/dev/null
  done < <(jq -r '.missed_detail[]? | [.[0], .[1]] | @tsv' "$rec" 2>/dev/null)
  n=$(find "$d/misses" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
  [ "$n" -gt 50 ] 2>/dev/null && find "$d/misses" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort | head -n "$((n-50))" \
    | while IFS= read -r dir; do rm -rf "$dir"; done
  return 0
}

ts_after_session() {
  local h="${1:-$(_ts_h)}" p="${2:-${PROJECT:-}}" rc="${3:-1}" out="${4:-}" key="${5:-}" hash="${6:-}" d mode gh=0 pfx
  local refs max nf=0 slug fetched=0 W DEC ROWS priv snap="" flog open_n hnd_n prc n
  local STAMP="${STAMP:-$(date -u '+%Y-%m-%d %H:%M:%SZ')}"
  [ -n "$h" ] && [ -n "$p" ] && [ -r "$out" ] || return 0
  HARNESS="$h"; PROJECT="$p"
  _ts_knobs "$p"
  mode=$(ts_mode "$h" "$p"); [ "$mode" = off ] && return 0
  d=$(_ts_dir "$p")
  [ -n "$key" ] || [ -s "$d/decisions.tsv" ] || return 0
  [ -n "$key" ] && [ -z "$hash" ] && return 0
  W="$d/world.json"; DEC="$d/decisions.tsv"; ROWS="$d/rows.json"; refs="$d/refs.tick.json"
  [ -e "$refs" ] || refs="$d/refs.json"
  if [ -n "$key" ]; then
    # A SHARD reads only the snapshot taken when it was dispatched. None (a
    # shard dispatched before this code): no world, so the stamp is the hash it
    # was handed — pre-session inputs, never a later tick's.
    # hash is <hash>.<nonce> from ts_shard_hash (the bare hash from an older
    # dispatcher): the nonce names this dispatch's own snapshot.
    case "$key$hash" in *[!A-Za-z0-9._-]*) return 0 ;; esac
    snap="$d/snap/$key.$hash"
    hash="${hash%%.*}"
    if [ -d "$snap" ]; then W="$snap/world.json"; DEC="$snap/decisions.tsv"; ROWS="$snap/rows.json"; refs="$snap/refs.json"
    else W=""; DEC=""; ROWS=""; fi
  fi
  jq -e 'has("issues")' "${W:-$d/world.json}" >/dev/null 2>&1 && gh=1
  [ "$gh" = 1 ] && pfx=$(_ts_prefix "$p")
  priv=$(mktemp "$d/refs.priv.XXXXXX" 2>/dev/null) || return 0
  jq -e 'type=="object"' "$refs" > "$priv" 2>/dev/null && cp -f "$refs" "$priv" || echo '{}' > "$priv"
  _ts_record_run || { rm -f "$d/record.$$.json" "$priv"; [ -n "$snap" ] && rm -rf "$snap"; return 0; }
  # A ref the NEW reason names that the pre-session state never placed (off the
  # fingerprint, not in refs.json) is looked up now, inside the fetch cap, into
  # the SHARED refs.json. Only an OPEN answer is stamped: a ref that is already
  # CLOSED / MERGED / MISSING may have settled DURING the session, after the
  # model read it, so it stays `absent` in the stamp and next tick's hash (which
  # sees the settled state) re-offers the ticket once instead of skipping it.
  if [ "$gh" = 1 ] && [ -n "$W" ] && [ "$(jq '.unresolved // [] | length' "$d/record.$$.json" 2>/dev/null)" -gt 0 ] 2>/dev/null \
     && ! _ts_gh_budget_low; then
    _ts_libs
    max=$(_ts_int "${TRIAGE_STATE_MAX_FETCH:-30}" 30 0)
    slug="${TRIAGE_GH_SLUG:-}"; [ -n "$slug" ] || slug=$("$h/bin/fleet-conf.sh" "$p" repo 2>/dev/null)
    flog=$(mktemp "$d/refs.fetched.XXXXXX" 2>/dev/null) && {
      jq -r '.unresolved[]' "$d/record.$$.json" > "$flog.n" 2>/dev/null
      refs="$d/refs.json"; _ts_refs_init "$refs"
      _TS_FETCH_LOG="$flog" _ts_fetch_refs "$flog.n"
      open_n=0
      while read -r n st; do
        [ "$st" = OPEN ] && { _ts_refs_merge "$priv" "$n" OPEN; open_n=$((open_n+1)); }
      done < "$flog"
      rm -f "$flog" "$flog.n"
      if [ "$open_n" -gt 0 ]; then _ts_record_run || { rm -f "$d/record.$$.json" "$priv"; [ -n "$snap" ] && rm -rf "$snap"; return 0; }; fi
    }
  fi
  rm -f "$priv" "$priv.lock"
  if [ "$mode" = shadow ] && [ "$(jq '.missed | length' "$d/record.$$.json" 2>/dev/null)" -gt 0 ] 2>/dev/null; then
    # THE SHADOW'S OWN SCORECARD: the session acted on a ticket the pre-check
    # would have kept from it. Before enforce, this line should be empty.
    _ts_log "triage-state shadow: would-have-missed $(jq '.missed | length' "$d/record.$$.json"): $(jq -r '.missed | join(", ")' "$d/record.$$.json" | cut -c1-600)"
    # and the gate reason of each, with the inputs it hashed kept in misses/
    _ts_log "triage-state shadow: miss-detail: $(jq -r '[.missed_detail[]? | "\(.[1])=\(.[3])"] | join(" ")' "$d/record.$$.json" | cut -c1-600)"
    _ts_miss_snapshot "$d" "$d/record.$$.json"
  fi
  [ -n "$snap" ] && rm -rf "$snap"
  # A DECISION that changed something on a skipped ticket with a queue line or
  # a finished build this tick: the session's work, which enforce leaves it
  # too (ts_tick). Not a miss, but kept as data.
  if [ "$mode" = shadow ] && [ "$(jq '.work // [] | length' "$d/record.$$.json" 2>/dev/null)" -gt 0 ] 2>/dev/null; then
    _ts_log "triage-state shadow: work-on-skip $(jq '.work | length' "$d/record.$$.json"): $(jq -r '.work | join(", ")' "$d/record.$$.json" | cut -c1-600)"
  fi
  # A DECISION on a skipped ticket that changed nothing (a `skip`, or the verdict
  # it already held): not a miss, but kept as data.
  if [ "$mode" = shadow ] && [ "$(jq '.noop // [] | length' "$d/record.$$.json" 2>/dev/null)" -gt 0 ] 2>/dev/null; then
    _ts_log "triage-state shadow: model-noop-on-skip $(jq '.noop | length' "$d/record.$$.json"): $(jq -r '.noop | join(", ")' "$d/record.$$.json" | cut -c1-600)"
  fi
  # BH-3920: the tickets the session was handed and returned nothing for. They
  # are held off the model for the backoff; the single session also leaves
  # hnd.last for the call-guard's stuck alert (ts_stuck_line). Only on rc 0: a
  # refused session (rc 74) records nothing, and launch.sh runs this before the
  # gate reads hnd.last, so writing it there would zero the count it alerts on.
  hnd_n=$(jq '.handed_no_decision // [] | length' "$d/record.$$.json" 2>/dev/null)
  case "$hnd_n" in ''|*[!0-9]*) hnd_n=0 ;; esac
  [ "$hnd_n" -gt 0 ] && _ts_log "triage-state: handed-no-decision $hnd_n: $(jq -r '.handed_no_decision | join(" ")' "$d/record.$$.json" | cut -c1-600) — the session returned no DECISION line for them; offered again after $(ts_hnd_backoff)s"
  [ -z "$key" ] && [ "$rc" = 0 ] && printf '%s\t%s\t%s\n' "$(_ts_now)" "$hnd_n" "$(jq -r '.handed_no_decision // [] | join(" ")' "$d/record.$$.json" 2>/dev/null | cut -c1-600)" > "$d/hnd.last"
  # BH-8497: the keys whose no-DECISION retries ran out this session. Each key
  # spends once (a spent reason stays spent), so this is one line per spend.
  if [ "$(jq '.no_decision_spent // [] | length' "$d/record.$$.json" 2>/dev/null)" -gt 0 ] 2>/dev/null; then
    HARNESS="$h" "$h/bin/alert-line.sh" --id "triage-no-decision:$p" --project "$p" \
      "[run-triage] $p: triage returned no DECISION line $(( $(ts_nd_retries) + 1 )) times for: $(jq -r '.no_decision_spent | join(" ")' "$d/record.$$.json" | cut -c1-600); their verdict is now final (triaged). Read state/triage-state/$p/rows.json" \
      >/dev/null 2>&1 || true
  fi
  n=$(jq '.rows | length' "$d/record.$$.json" 2>/dev/null)
  if [ "$n" -gt 0 ] 2>/dev/null; then
    _ts_libs
    if command -v triage_state_put >/dev/null 2>&1; then
      triage_state_put "$d/record.$$.json" >/dev/null 2>&1; prc=$?
      [ "$prc" = 0 ] || _ts_log "triage-state: recording $n row(s) failed (rc $prc) — the verdicts are not on the rows"
    fi
  fi
  rm -f "$d/record.$$.json"
  return 0
}

# ts_stuck_line <project> <attempts> <fingerprint> — BH-3920: the ALERTS text
# for a triage the call-guard refused <attempts> times in a row on the same
# full prompt (bin/lib/rt/gate.sh rt_gate_fail_consume). Names the keys still
# in the model set (decisions.tsv `llm`) and why they are stuck: the last
# single session's hand-off count (hnd.last, when younger than 2x the backoff),
# else the model set broken down by reason.
ts_stuck_line() {
  local p="${1:-${PROJECT:-}}" n="${2:-?}" sha="${3:-none}" d dec k=0 labels="" why hl at hn
  d=$(_ts_dir "$p"); dec="$d/decisions.tsv"
  if [ -n "$d" ] && [ -r "$dec" ]; then
    k=$(awk -F'\t' '$3=="llm"' "$dec" | wc -l | tr -d ' ')
    labels=$(awk -F'\t' '$3=="llm" {printf "%s ", $2}' "$dec" | sed 's/ $//' | cut -c1-600)
    hl=$(head -1 "$d/hnd.last" 2>/dev/null)
    at=$(printf '%s' "$hl" | cut -f1); hn=$(printf '%s' "$hl" | cut -f2)
    case "$at$hn" in ''|*[!0-9]*) hn=0 ;; esac
    if [ "${hn:-0}" -gt 0 ] && [ $(( $(_ts_now) - at )) -lt $(( 2 * $(ts_hnd_backoff) )) ]; then
      why="model returned no DECISION for $hn handed keys (last session $(_ts_iso "$at"))"
    else
      why=$(awk -F'\t' '$3=="llm" {c[$4]++} END {for (r in c) printf "%s\t%d\n", r, c[r]}' "$dec" \
        | sort -t "$(printf '\t')" -k2,2nr -k1,1 | awk -F'\t' '{printf "%s%s=%s", (NR>1 ? " " : ""), $1, $2}')
      [ -n "$why" ] || why="nothing is in the model set"
    fi
  else
    why="no decisions.tsv on this box"
  fi
  printf '[%s] triage is stuck: the call-guard refused the same full triage %s times (fingerprint %s). %s key(s) in the model set: %s. Reason: %s. Read: logs/call-guard.log and state/triage-state/%s/decisions.tsv.' \
    "$p" "$n" "$sha" "$k" "${labels:-none}" "$why" "$p"
}
