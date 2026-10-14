#!/bin/bash
# bin/lib/triage-state-pr.sh — the PR half of the TRIAGE-STATE pre-check
# (BH-3417). bin/lib/triage-state.sh gates tickets; the board's `board prs:`
# lines still reach the model on every tick they appear in. This file holds the
# seams the PR pre-check is built on. Sourced by bin/lib/triage-state.sh
# (_ts_libs); defines functions only, nothing runs on source.
# Doc: docs/notes/2026-09-29-BH-3417-pr-triage-state.md.
#
# ts_pr_precheck (BH-3419) decides every `board prs:` key of the tick before a
# model call: a Mergify merge-queue draft is `draft`, a PR the board says is
# closed is stamped `closed` (bin/triage-state.py decide), an open PR is hashed
# (bin/triage-state-pr.py pr-hash: head, labels, Mergify state, reviews on the
# head, the lead's standing verdict, the newest comment not ours) and compared
# with the row's verdict_hash. Any read that fails, and the fetch cap spent,
# is hash `-`: the model decides, never "unchanged" and never "closed".
# ts_tick drops a pr-* key from the shard loop only in enforce, only on an
# enforce gate reason (TS_PR_ENFORCING); shadow logs and records the rows only.
# A PR key is never enqueued and never reaches bin/run-build.sh.
#
# The root is _ts_h (HARNESS, then the caller's H, else none), the same as
# triage-state.sh (BH-2613): with no root nothing is read or written.
#
# Knob (catalog/lanes.d/_lib.triage-state.json), settings rows through
# lib_env_apply, then env:
#   PR_STATE_MODE   off | shadow | enforce (default shadow)
# Kill switch: lane_switch triage-state-off file, shared with the ticket gate.

# ts_pr_mode <project> — off | shadow | enforce for the PR pre-check. The kill
# switch first; then the settings rows (per project, then fleet); then the env.
# Anything unreadable is `shadow`.
ts_pr_mode() {
  local p="${1:-${PROJECT:-}}" m
  _ts_libs
  # No lane-switch lib (a box mid-sync): the file alone decides, as it would.
  command -v lane_switch >/dev/null 2>&1 || lane_switch() { [ -n "$(_ts_h)" ] && [ -e "$(_ts_h)/flags/$1" ]; }
  lane_switch triage-state-off file && { printf 'off'; return 0; }
  command -v lib_env_apply >/dev/null 2>&1 && lib_env_apply triage-state "$p" >/dev/null 2>&1
  m="${PR_STATE_MODE:-shadow}"
  case "$m" in off|shadow|enforce) printf '%s' "$m" ;; *) printf 'shadow' ;; esac
}

# _ts_prs_json <project> <dir> — this tick's open PRs into <dir>/prs.json, read
# once per tick (ts_precheck removes the file at the top of the tick). A read
# that fails, or no repo slug, leaves the marker `unreadable`, which a caller
# reads as "cannot answer". Always rc 0.
_ts_prs_json() {
  local h p="$1" d="$2" slug
  h=$(_ts_h)
  if [ ! -e "$d/prs.json" ]; then
    slug="${TRIAGE_GH_SLUG:-}"
    [ -n "$slug" ] || slug=$("$h/bin/fleet-conf.sh" "$p" repo 2>/dev/null)
    if [ -n "$slug" ] && command -v gh_rest_pr_list >/dev/null 2>&1 \
       && gh_rest_pr_list "$slug" open "" 100 > "$d/prs.json.t" 2>/dev/null \
       && jq -e 'type=="array"' "$d/prs.json.t" >/dev/null 2>&1; then
      mv -f "$d/prs.json.t" "$d/prs.json"
    else
      rm -f "$d/prs.json.t"; echo unreadable > "$d/prs.json"
    fi
  fi
  return 0
}

# _ts_pr_keys — `pr-<n><TAB><verb>` for every `board prs:` line of this tick's
# board scope (TICK_SCOPE, BOARD_SEC minus its header), keyed by the shard
# loop's own triage_shard_key (_ts_key_of), so a key here is the key the shard
# loop asks ts_unit_skip about. A key named twice keeps its LAST verb; a line
# nobody can place is dropped.
_ts_pr_keys() {
  local line k v
  while IFS= read -r line; do
    line=${line#'[HOTFIX] '}
    case "$line" in 'board prs: '*) ;; *) continue ;; esac
    k=$(_ts_key_of board "$line") || continue
    v=$(printf '%s' "$line" | sed -nE 's/^board prs: ([A-Z]+) .*/\1/p')
    [ -n "$k" ] && [ -n "$v" ] && printf '%s\t%s\n' "$k" "$v"
  done <<<"${TICK_SCOPE:-}
$(printf '%s' "${BOARD_SEC:-}" | tail -n +2)" \
  | awk -F'\t' '!($1 in v) {o[++n]=$1} {v[$1]=$2} END {for (i=1; i<=n; i++) printf "%s\t%s\n", o[i], v[o[i]]}'
}

# _ts_pr_thread <key> <file> — one PR thread read (bin/triage-gate.sh --thread)
# inside the per-tick cap, in ts_pr_precheck's scope ($h $p $nofetch $nf $max).
# rc 0 with the gh wrap in <file>; rc 1 when the cap is spent, the GitHub
# budget is low or the read failed. One count per PR: the open path's reviews
# read rides the same count.
_ts_pr_thread() {
  [ "$nofetch" = 0 ] && [ "$nf" -lt "$max" ] || return 1
  nf=$((nf+1))
  "$h/bin/triage-gate.sh" "$p" --thread "$1" > "$2" 2>/dev/null </dev/null && [ -s "$2" ] \
    && jq -e '.kind == "gh" and (.doc.issue | type == "object")' "$2" >/dev/null 2>&1
}

_ts_nw() { printf '%s' "$1" | wc -w | tr -d ' '; }

# ts_pr_precheck <project> — the PR pre-check. Sets the four variables ts_tick
# reads:
#   TS_PR_MODE     off | shadow | enforce (ts_pr_mode)
#   TS_PR_READY    1 when every PR key of the tick was decided, else 0
#   TS_PR_SKIPSET  " pr-N pr-M " — the keys decided skip, stamp or draft
#   TS_PR_DRAFTS   the Mergify draft keys, one per line
# Writes state/triage-state/<p>/pr-decisions.tsv (key, key, decision, reason,
# hash, seed, 1, -), one observe row per non-draft key and one lane-log line.
# Returns before any read, row or log line when the mode is off, the tick names
# no PR, or the board is not a GitHub-Issues board. Always rc 0.
ts_pr_precheck() {
  local h p d t world py ppy keys slug max nf=0 nofetch=0 prs_ok=0 key verb n row hash op rc lead line
  local rows_ok=1 dec reason seed rest llm="" skip_n=0 stamped="" drafts="" n_all=0 v
  TS_PR_MODE=off; TS_PR_READY=0; TS_PR_SKIPSET=" "; TS_PR_DRAFTS=""
  h=$(_ts_h); p="${1:-}"
  [ -n "$h" ] && [ -n "$p" ] || return 0
  _ts_knobs "$p"
  TS_PR_MODE=$(ts_pr_mode "$p")
  [ "$TS_PR_MODE" = off ] && return 0
  py="$h/bin/triage-state.py"; ppy="$h/bin/triage-state-pr.py"
  command -v jq >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1 && [ -r "$py" ] && [ -r "$ppy" ] || return 0
  keys=$(_ts_pr_keys)
  [ -n "$keys" ] || return 0
  # The board fingerprint ts_precheck selects, read here directly: the ticket
  # pre-check copies it only when its own mode is on.
  world="$h/state/$p.gate.pending"; [ -s "$world" ] || world="$h/state/$p.gate.json"
  jq -e 'type == "object" and has("issues")' "$world" >/dev/null 2>&1 || return 0
  d=$(_ts_dir "$p")
  mkdir -p "$d" 2>/dev/null && t=$(mktemp -d "$d/pr.XXXXXX" 2>/dev/null) || return 0
  rm -f "$d/pr-decisions.tsv"
  export PYTHONDONTWRITEBYTECODE=1
  slug="${TRIAGE_GH_SLUG:-}"; [ -n "$slug" ] || slug=$("$h/bin/fleet-conf.sh" "$p" repo 2>/dev/null)
  _ts_prs_json "$p" "$d"
  jq -e 'type == "array"' "$d/prs.json" >/dev/null 2>&1 && prs_ok=1
  max=$(_ts_int "${TRIAGE_STATE_MAX_FETCH:-30}" 30 0)
  _ts_gh_budget_low && nofetch=1
  : > "$d/pr-hashes.tsv"
  while IFS=$'\t' read -r -u 3 key verb; do
    n=${key#pr-}; hash=-; op=1; row=""; n_all=$((n_all+1))
    [ "$prs_ok" = 1 ] && row=$(jq -c --argjson n "$n" 'first(.[] | select(.number == $n)) // empty' "$d/prs.json" 2>/dev/null)
    if [ -n "$row" ] && python3 "$ppy" pr-draft --title "$(jq -r '.title // ""' <<<"$row")" \
         --head-ref "$(jq -r '.head.ref // ""' <<<"$row")" >/dev/null 2>&1 </dev/null; then
      drafts="$drafts $key"; continue
    fi
    if [ "$verb" = REMOVED ] || { [ "$prs_ok" = 1 ] && [ -z "$row" ]; }; then
      # Gone from the board, or missing from the 100-capped open list: only the
      # thread can say closed. Unread or still open stays `-` (the model).
      if _ts_pr_thread "$key" "$t/$key.raw"; then
        if python3 "$ppy" pr-draft --title "$(jq -r '.doc.issue.title // ""' "$t/$key.raw")" --head-ref "" >/dev/null 2>&1 </dev/null; then
          drafts="$drafts $key"; continue
        fi
        [ "$(jq -r '.doc.issue.state // ""' "$t/$key.raw" 2>/dev/null)" = closed ] && op=0
      fi
    elif [ -n "$row" ] && _ts_pr_thread "$key" "$t/$key.raw"; then
      printf '%s' "$row" > "$t/$key.pr"
      if gh_rest GET "repos/$slug/pulls/$n/reviews" -F per_page=100 > "$t/$key.rev" 2>/dev/null </dev/null \
         && jq -e 'type == "array"' "$t/$key.rev" >/dev/null 2>&1; then
        lead=$(vd_standing "$slug" "$n" "$(jq -r '.head.sha // ""' <<<"$row")" 2>/dev/null </dev/null); rc=$?
        case "$rc" in 0) lead=$(head -1 <<<"$lead" | cut -f1-3) ;; 1) lead=none ;; *) lead="" ;; esac
        if [ -n "$lead" ] && printf '%s\n' "$lead" > "$t/$key.lead"; then
          hash=$(python3 "$ppy" pr-hash --thread "$t/$key.raw" --pr "$t/$key.pr" --reviews "$t/$key.rev" \
                   --lead "$t/$key.lead" 2>/dev/null </dev/null) || hash=-
          [[ "$hash" =~ ^[0-9a-f]{64}$ ]] || hash=-
        fi
      fi
    fi
    # hashes.tsv, bin/triage-state.py decide's input: key label hash lua open seed base reason-deps
    printf '%s\t%s\t%s\t-\t%s\t-\t-\t-\n' "$key" "$key" "$hash" "$op" >> "$d/pr-hashes.tsv"
  done 3<<<"$keys"
  # The rows, one get per key (never the 1000-row list): a 404 is no row, any
  # other failure makes every row unreadable (every PR to the model).
  : > "$t/rows"
  for key in $(cut -f1 "$d/pr-hashes.tsv"); do
    line=$(triage_state_get "$p" "$key" 2>/dev/null </dev/null); rc=$?
    case "$rc" in 0) printf '%s\n' "$line" >> "$t/rows" ;; 2) ;; *) rows_ok=0; break ;; esac
  done
  [ "$rows_ok" = 1 ] && jq -s 'if all(type == "object") then . else error end' "$t/rows" > "$d/pr-rows.json" 2>/dev/null || { rows_ok=0; echo null > "$d/pr-rows.json"; }
  : > "$d/pr-decided.tsv"
  if [ -s "$d/pr-hashes.tsv" ] && ! python3 "$py" decide --hashes "$d/pr-hashes.tsv" --rows "$d/pr-rows.json" --now "$(_ts_now)" \
       --ttl "$(ts_ttl)" --defer-ttl "$(ts_defer_ttl)" --world "$world" --decisions /dev/null --project "$p" \
       --prefix "" --keymap "" --gh 1 > "$d/pr-decided.tsv" 2>/dev/null </dev/null; then
    _ts_log "triage-state-pr $TS_PR_MODE: the decision pass failed — nothing decided, every PR to the model"
    rm -rf "$t"; return 0
  fi
  : > "$t/decisions"
  while IFS=$'\t' read -r -u 3 key _ hash _ op _; do
    line=$(awk -F'\t' -v k="$key" '$1 == k {print; exit}' "$d/pr-decided.tsv")
    if [ -n "$line" ]; then
      IFS=$'\t' read -r _ _ dec reason hash seed _ <<<"$line"
      # a stored `buildable` on a PR is never a launch
      [ "$dec" = candidate ] && { dec=skip; reason=unchanged:buildable; }
    elif [ "$op" = 0 ] && [ "$rows_ok" = 1 ]; then
      dec=skip; reason=terminal; hash=-; seed=-      # already stamped closed
    else
      dec=llm; reason=rows-unreadable; hash=-; seed=-
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t1\t-\n' "$key" "$key" "$dec" "$reason" "$hash" "$seed" >> "$t/decisions"
  done 3< "$d/pr-hashes.tsv"
  for key in $drafts; do printf '%s\t%s\tdraft\t-\t-\t-\t1\t-\n' "$key" "$key" >> "$t/decisions"; done
  mv -f "$t/decisions" "$d/pr-decisions.tsv" || { rm -rf "$t"; return 0; }
  awk -F'\t' '$3 != "draft"' "$d/pr-decisions.tsv" > "$d/pr-observe.tsv"
  [ -s "$d/pr-observe.tsv" ] && TS_MODE="$TS_PR_MODE" _ts_observe "$p" "$d/pr-observe.tsv"
  while IFS=$'\t' read -r -u 3 key _ dec _; do
    case "$dec" in
      llm) llm="$llm $key" ;;
      skip) skip_n=$((skip_n+1)); TS_PR_SKIPSET="$TS_PR_SKIPSET$key " ;;
      stamp) stamped="$stamped $key"; TS_PR_SKIPSET="$TS_PR_SKIPSET$key " ;;
      draft) TS_PR_SKIPSET="$TS_PR_SKIPSET$key "; TS_PR_DRAFTS="${TS_PR_DRAFTS:+$TS_PR_DRAFTS$'\n'}$key" ;;
    esac
  done 3< "$d/pr-decisions.tsv"
  TS_PR_READY=1
  rm -rf "$t"
  # `skipped` only when ts_tick will act on it (enforce on an enforce reason).
  v="would skip"; [ "$TS_PR_MODE" = enforce ] && _ts_enforce_reason && v=skipped
  rest=""; [ "$rows_ok" = 0 ] && rest=" (rows unreadable: every PR to the model)"
  _ts_log "triage-state-pr $TS_PR_MODE: $n_all PR(s), $(_ts_nw "$llm") to the model${llm:+:$llm}, $skip_n unchanged, $(_ts_nw "$stamped") stamped terminal${stamped:+:$stamped}, $v $(_ts_nw "$drafts") mergify draft(s)${drafts:+:$drafts}$rest [reads=$nf]"
  return 0
}
