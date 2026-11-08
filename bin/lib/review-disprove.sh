#!/bin/bash
# shellcheck shell=bash
# bin/lib/review-disprove.sh — the disprove pass on a lead review BLOCK and on
# a conductor re-review BLOCK (BH-9047). Sourced by bin/lead-review.sh and by
# mc_rereview (bin/lib/mc/rebase.sh), never run. Defines functions only.
# The root is ${HARNESS:-${H:-}}; an empty root is no pass, never a guessed path.
#
# After the lead verdict is BLOCK (and after the re-review downgrade, break-it
# and the review level cap), ONE bounded model call per model BLOCK finding on
# route review-disprove asks: prove this finding wrong from the code, or
# confirm it with the exact line. The answer's LAST non-blank line decides:
#   CONFIRMED <path>:<line>           the finding stands
#   DISPROVED <reason> <path>:<line>  DISPROVED only when <path> is in the head
#                                     tree and <line> is a line of it
# Anything else, a failed call or an empty answer counts as CONFIRMED: a BLOCK
# never drops because the check failed (fail closed).
#
# shadow (the default mode) records and changes nothing. enforce rewrites the
# review out: a DISPROVED finding becomes `- [NOTE] disproved: (<class>) ...`,
# a DISPROVED protected finding (any class but the exact droppable ones in
# _dp_droppable, and any line that holds GUARD_SILENCED or FRAUD:) keeps its
# BLOCK and gains `| disprove-said:`, and only when no line of any finding
# shape still reads as a BLOCK and no `NEEDS_HUMAN:` line stands
# (_dp_blocks_left; in the conductor lane also no BLOCK word on any line
# outside a fence, _dp_stray_block) the verdict is the lane's clearing word (_dp_clear_word:
# MERGE-WITH-NOTES for the lead review, APPROVE for the conductor).
#
# The lane (C1): DP_LANE=lead (the default) or conductor picks the verdict
# reader (_dp_verdict), the clearing word, and the record's lane and actor.
# DP_DIR (default <wt>.dp) is where the pass writes its files.
#
# Settings rows (dp_knob; each fallback is the value in brackets):
#   review.disprove.<project>.enabled [0]  exactly 1 = on
#   review.disprove.mode [shadow]          shadow|enforce, trimmed, lowercased
#   review.disprove.max_findings [5] 1..20 review.disprove.usd_cap_day [2] >0, <=50
#   review.disprove.call_budget_usd [0.50] >0, <=5
#   review.disprove.max_context_bytes [24000] 2000..200000
#   review.disprove.min_left_s [120] 30..3600
#   review.disprove.conductor_left_s [900] 60..3600 (dpc_run only)
#
# dp_review <repo> <pr> <head> <project> <wt> <base> <out> <left-s> <review-id>
#   The reviewer's entry. Prints ONE line `<result> <mode> <rewrote>`. result
#   is `ran` or `skipped:<off|not-block|no-root|no-route|no-prompt|no-finding>`.
#   rewrote is 1 only in enforce when <out> changed. Writes <DP_DIR>/report (the
#   header line and one indented line per finding) and <DP_DIR>/record.json (the
#   POST /api/review-disprove body), and posts it (dp_record).
#
# dpc_gate_on <project> / dpc_run <slug> <num> <project> <head> <out> <rid>
#   The conductor lane (C1), below dp_review.

_dp_root() { printf '%s' "${HARNESS:-${H:-}}"; }
# _dp_lane — conductor when DP_LANE says so, else lead.
_dp_lane() { if [ "${DP_LANE:-lead}" = conductor ]; then printf conductor; else printf lead; fi; }
# _dp_clear_word — the verdict word enforce writes when no BLOCK is left: the
# lead review's MERGE-WITH-NOTES, or APPROVE for the conductor, whose reader
# (verdict_parse) knows only APPROVE|BLOCK.
_dp_clear_word() { if [ "$(_dp_lane)" = conductor ]; then printf APPROVE; else printf MERGE-WITH-NOTES; fi; }
# _dp_verdict <file> <fallback> — the lane's verdict reader on <file>: lr_verdict
# (lead) or verdict_parse (conductor; `unknown` when it cannot read one).
# <fallback> when the reader is not loaded.
_dp_verdict() {
  local v
  if [ "$(_dp_lane)" = conductor ]; then
    command -v verdict_parse >/dev/null 2>&1 || { printf '%s' "$2"; return 0; }
    v=$(verdict_parse "$1" 2>/dev/null) || v=unknown
  else
    command -v lr_verdict >/dev/null 2>&1 || { printf '%s' "$2"; return 0; }
    v=$(lr_verdict "$1")
  fi
  printf '%s' "$v"
}
_dp_log() {
  if command -v log >/dev/null 2>&1; then log "disprove: $*"; else printf 'disprove: %s\n' "$*" >&2; fi
}

# dp_knob <name> — the review.disprove.<name> row with all space removed. rc 1
# = no row, an unreadable row or an empty value (the caller uses its fallback).
dp_knob() {
  local v
  command -v setting_get >/dev/null 2>&1 || return 1
  v=$(setting_get "review.disprove.$1" 2>/dev/null 7>&- 8>&-) || return 1
  v=$(printf '%s' "$v" | tr -d '[:space:]')
  [ -n "$v" ] || return 1
  printf '%s' "$v"
}

# dp_gate <project> — off | shadow | enforce. On only when the row
# review.disprove.<project>.enabled reads exactly 1 (fallback 0 = off).
dp_gate() {
  local e m
  case "$1" in ''|*[!A-Za-z0-9._-]*) printf off; return 0 ;; esac
  e=$(dp_knob "$1.enabled") || e=""
  [ "$e" = 1 ] || { printf off; return 0; }
  m=$(dp_knob mode | tr '[:upper:]' '[:lower:]')
  if [ "$m" = enforce ]; then printf enforce; else printf shadow; fi
}

# _dp_int <name> <lo> <hi> <fallback> — a whole number in lo..hi, else fallback.
_dp_int() {
  local v; v=$(dp_knob "$1") || v=""
  if [[ "$v" =~ ^[0-9]{1,9}$ ]] && [ "$((10#$v))" -ge "$2" ] && [ "$((10#$v))" -le "$3" ]; then printf '%s' "$((10#$v))"
  else printf '%s' "$4"; fi
}
# _dp_usd <name> <hi> <fallback> — a decimal > 0 and <= hi, else fallback.
_dp_usd() {
  local v; v=$(dp_knob "$1") || v=""
  if [[ "$v" =~ ^[0-9]{1,3}(\.[0-9]{1,4})?$ ]] && awk -v b="$v" -v h="$2" 'BEGIN { exit !(b > 0 && b <= h) }'; then printf '%s' "$v"
  else printf '%s' "$3"; fi
}

# _dp_droppable <class> — rc 0 only when <class>, trimmed and lower-cased, is
# exactly one of the ALWAYS-BLOCK classes enforce may drop. Every other class
# (secret, tenant-leak, auth-bypass, money, data-loss, destructive-migration,
# an untagged line, `Secret`, `auth bypass`, `secret, money`, any unknown
# word) is protected: a class that cannot be read is never judged safe.
_dp_droppable() {
  case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
    wrong-data|core-flow-broken|user-flows|hardcoded-knob|scalable-tests|weakened-test|model-id) return 0 ;;
  esac
  return 1
}

# _dp_path_ok <path> — rc 1 for a path that starts with `-` or `/` or holds
# `..`: it is no location (dp_extract) and no proof (_dp_line_ok).
_dp_path_ok() { case "$1" in ''|-*|/*|*..*) return 1 ;; esac; return 0; }

# dp_extract <out> — one TSV line per `- [BLOCK` finding at column 0 outside a
# ``` fence: <line-no> <kind> <protected 0|1> <class|-> <path:n[-m]|->.
# kind: check (has a location), noloc, or skip (a mechanical class or a
# break-it line: no call, not a model finding). Protected unless _dp_droppable,
# and always protected when the line holds GUARD_SILENCED or FRAUD: (the
# conductor prompt makes both an automatic BLOCK).
dp_extract() {
  local l n=0 f=0 cls rest loc kind prot
  local re_find='^- \[BLOCK([^]]*)\] ?(.*)$' re_loc='^`?([A-Za-z0-9._/-]+):([0-9]+)(-[0-9]+)?'
  while IFS= read -r l || [ -n "$l" ]; do
    n=$((n + 1)); l="${l%$'\r'}"
    if [[ "$l" =~ ^[[:space:]]*\`\`\` ]]; then f=$((1 - f)); continue; fi
    [ "$f" = 1 ] && continue
    [[ "$l" =~ $re_find ]] || continue
    cls="${BASH_REMATCH[1]}"; rest="${BASH_REMATCH[2]}"
    case "$cls" in " "*) cls=$(printf '%s' "$cls" | tr -s '[:space:]' ' ' | sed 's/^ //; s/ $//') ;; *) cls="" ;; esac
    loc=""; kind=noloc; prot=1
    if [[ "$rest" =~ $re_loc ]] && [ "$((10#${BASH_REMATCH[2]}))" -ge 1 ] && _dp_path_ok "${BASH_REMATCH[1]}"; then
      loc="${BASH_REMATCH[1]}:$((10#${BASH_REMATCH[2]}))${BASH_REMATCH[3]}"; kind=check
    fi
    case "$(printf '%s' "$cls" | tr '[:upper:]' '[:lower:]')" in needs-human|split-required|red-build) kind=skip ;; esac
    case "$rest" in break-it:*) kind=skip ;; esac
    { [ "$kind" = skip ] || _dp_droppable "$cls"; } && prot=0
    case "$l" in *GUARD_SILENCED*|*FRAUD:*) [ "$kind" = skip ] || prot=1 ;; esac
    printf '%s\t%s\t%s\t%s\t%s\n' "$n" "$kind" "$prot" "${cls:--}" "${loc:--}"
  done < "$1"
}

# _dp_line_ok <wt> <head> <path> <n> — rc 0 when <path> is a file in the head
# tree and <n> (>= 1) is one of its lines.
_dp_line_ok() {
  local c
  _dp_path_ok "$3" || return 1
  [[ "$4" =~ ^[0-9]{1,9}$ ]] && [ "$((10#$4))" -ge 1 ] || return 1
  git -C "$1" cat-file -e "$2:$3" 2>/dev/null || return 1
  c=$(git -C "$1" show "$2:$3" 2>/dev/null | awk 'END { print NR }')
  [ "$((10#$4))" -le "${c:-0}" ]
}

# dp_parse_answer <answer> <wt> <head> — prints `<CONFIRMED|DISPROVED><TAB><reason>`.
# Only the LAST non-blank line counts, matched exactly in upper case.
dp_parse_answer() {
  local last txt c p n
  last=$(tr -d '\r' < "$1" 2>/dev/null | awk 'NF { l = $0 } END { print l }' | sed 's/[[:space:]]*$//')
  if [[ "$last" =~ ^DISPROVED\ (.+)$ ]]; then
    txt="${BASH_REMATCH[1]}"
    while IFS= read -r c; do
      [[ "$c" =~ ^(.+):([0-9]+)(-[0-9]+)?$ ]] || continue
      p="${BASH_REMATCH[1]}"; n="${BASH_REMATCH[2]}"
      if _dp_line_ok "$2" "$3" "$p" "$n"; then
        printf 'DISPROVED\t%s\n' "$(printf '%s' "$txt" | tr -d '[]`\r' | head -c 300)"; return 0
      fi
    done < <(printf '%s\n' "$txt" | grep -oE '[A-Za-z0-9._/-]+:[0-9]+(-[0-9]+)?')
    printf 'CONFIRMED\t%s\n' "a DISPROVED answer with no path:line in the head: $(printf '%s' "$txt" | tr -d '[]`\r' | head -c 200)"; return 0
  fi
  if [[ "$last" =~ ^CONFIRMED(\ (.*))?$ ]]; then
    printf 'CONFIRMED\t%s\n' "$(printf '%s' "${BASH_REMATCH[2]}" | tr -d '[]`\r' | head -c 300)"; return 0
  fi
  printf 'CONFIRMED\t%s\n' "no CONFIRMED or DISPROVED last line"
}

# dp_context <wt> <base> <head> <path> <n> <m> <max-bytes> — the prompt's
# `## Hunk` and `## File at head` sections, cut together at <max-bytes>.
dp_context() {
  local wt="$1" base="$2" head="$3" p="$4" n="$5" m="$6" max="$7" lo hi s
  lo=$((n > 40 ? n - 40 : 1)); hi=$((m + 40))
  s=$( {
    printf '## Hunk\n\n'
    git -C "$wt" diff "origin/$base...$head" -- "$p" 2>/dev/null || printf '(the diff could not be read)\n'
    printf '\n## File at head (%s, lines %s-%s)\n\n' "$p" "$lo" "$hi"
    if git -C "$wt" cat-file -e "$head:$p" 2>/dev/null; then
      git -C "$wt" show "$head:$p" 2>/dev/null | awk -v lo="$lo" -v hi="$hi" 'NR >= lo && NR <= hi { printf "%6d  %s\n", NR, $0 }'
    else printf '(%s is not in the PR head)\n' "$p"; fi
  } | head -c "$max"; printf x)
  printf '%s' "${s%x}"
  [ "${#s}" -le "$max" ] || printf '\n[the hunk and the file are cut at %s bytes]\n' "$max"
}

# _dp_blocks_left <file> — rc 0 when a line still stops the merge: any finding
# shape the reviewer counts (bin/lib/review-level.sh RL_FIND_RE marker grammar
# with a RL_BLOCKWORD_RE word: `* [BLOCK x]`, `1. **[BLOCK x]**`, an indented
# `- [BLOCK x]`, `[BLOCKING — x]`, `**[HIGH]**`; any case, fenced or not) or a
# `NEEDS_HUMAN:` line. dp_extract only checks `- [BLOCK` at column 0, so a
# BLOCK of any other shape was never checked and must hold the verdict.
_dp_blocks_left() {
  local w='\[?(BLOCK|BLOCKING|BLOCKER|HIGH|MEDIUM|MAJOR|CRITICAL)([]:[:space:](—-]|\*\*|$)'
  w="${RL_BLOCKWORD_RE:-$w}"
  grep -qiE "^[[:space:]]*([-*]|[0-9]+[.)])?[[:space:]]*(\*\*)?$w" "$1" && return 0
  grep -qE '^[[:space:]]*NEEDS_HUMAN:' "$1" && return 0
  [ "$(_dp_lane)" = conductor ] && _dp_stray_block "$1"
}

# _dp_stray_block <file> — conductor lane only: rc 0 when a line outside a
# ``` fence holds the word BLOCK, BLOCKING or BLOCKER (any case). The
# conductor prompt is free-form, with no template and no lr_block_no_finding
# check, so a BLOCK in a heading (`### 1. [BLOCK data-loss]`), a table row
# (`| 2 | BLOCK (money) |`) or prose must hold the verdict. Not counted: the
# last VERDICT line (the one the rewrite replaces) and a `- [NOTE] disproved:`
# line the rewrite wrote. A false hold keeps BLOCK (fail closed).
_dp_stray_block() {
  awk -v last="$(awk '/^[*]*VERDICT:/ { l = NR } END { print l + 0 }' "$1")" '
    /^[[:space:]]*(```|~~~)/ { f = !f; next }
    f || NR == last || /^- \[NOTE\] disproved:/ { next }
    { if (toupper($0) ~ /(^|[^A-Z0-9_])BLOCK(ING|ER)?([^A-Z0-9_]|$)/) { hit = 1; exit } }
    END { exit hit ? 0 : 1 }' "$1"
}

# _dp_rewrite_pass <file> <hold> — print <file> with the `rep` lines of
# dp_rewrite replaced (it reads dp_rewrite's local `rep`). <hold> 1 keeps a
# DISPROVED line a BLOCK.
_dp_rewrite_pass() {
  local l n=0 o c rs
  while IFS= read -r l || [ -n "$l" ]; do
    n=$((n + 1))
    if [ -n "${rep[$n]:-}" ]; then
      IFS=$'\t' read -r o c rs <<<"${rep[$n]}"
      l="${l%$'\r'}"
      if [ "$o" = D ] && [ "$2" = 0 ]; then
        [[ "$l" =~ ^-\ \[BLOCK[^]]*\]\ ?(.*)$ ]] && l="- [NOTE] disproved: ($c) ${BASH_REMATCH[1]} | disprove: $rs"
      elif [ "$o" = D ]; then
        l="$l | disprove-said: DISPROVED $rs (kept: another BLOCK holds the verdict)"
      else
        case "$l" in
          *GUARD_SILENCED*|*FRAUD:*) l="$l | disprove-said: DISPROVED $rs (kept: a GUARD_SILENCED or FRAUD: finding is never auto-dropped)" ;;
          *) l="$l | disprove-said: DISPROVED $rs (kept: $c is never auto-dropped)" ;;
        esac
      fi
    fi
    printf '%s\n' "$l"
  done < "$1"
}

# dp_rewrite <out> <outcomes> — enforce only. <outcomes> is the TSV
# <line-no> <outcome> <protected> <class> <loc> <reason>. rc 0 = <out> was
# rewritten and still reads a verdict; rc 1 = nothing to rewrite; rc 3 = the
# rewrite left no readable verdict and <out> is restored.
dp_rewrite() {
  local out="$1" oc="$2" no o pr c lc rs v
  local -A rep=()
  while IFS=$'\t' read -r no o pr c lc rs; do
    [ "$c" = - ] && c=untagged
    case "$o" in
      DISPROVED) rep[$no]="D"$'\t'"$c"$'\t'"$rs" ;;
      KEPT) rep[$no]="K"$'\t'"$c"$'\t'"$rs" ;;
    esac
  done < "$oc"
  [ "${#rep[@]}" -gt 0 ] || return 1
  cp -f "$out" "$out.dpkeep" 2>/dev/null || return 1
  _dp_rewrite_pass "$out.dpkeep" 0 > "$out.dpnew"
  # A BLOCK the pass did not check (another shape, NEEDS_HUMAN:) holds the
  # verdict. If no `- [BLOCK` line is left, lr_block_no_finding
  # (bin/lib/lead-review/outcome-cap.sh) refuses the report and the review is
  # lost: keep every DISPROVED line a BLOCK and add the disprove text instead.
  if _dp_blocks_left "$out.dpnew" && ! grep -q '^- \[BLOCK' "$out.dpnew"; then
    _dp_rewrite_pass "$out.dpkeep" 1 > "$out.dpnew"
  fi
  if ! _dp_blocks_left "$out.dpnew"; then
    awk -v last="$(awk '/^[*]*VERDICT:/ { l = NR } END { print l + 0 }' "$out.dpnew")" -v w="$(_dp_clear_word)" \
      'NR == last { print "VERDICT: " w; next } { print }' "$out.dpnew" > "$out.dpnew2" && mv -f "$out.dpnew2" "$out.dpnew"
  fi
  mv -f "$out.dpnew" "$out" || { mv -f "$out.dpkeep" "$out"; return 3; }
  v=$(_dp_verdict "$out" unknown)
  if [ "$v" = unknown ]; then mv -f "$out.dpkeep" "$out"; return 3; fi
  rm -f "$out.dpkeep"
  return 0
}

# dp_record <body-file> — POST /api/review-disprove. A failed post is one log
# line; the review stands either way.
dp_record() {
  command -v _jobs_req >/dev/null 2>&1 || { _dp_log "no jobs client; the run is not recorded"; return 1; }
  _jobs_req POST /api/review-disprove "$(cat "$1")" >/dev/null 2>&1 7>&- 8>&- \
    || { _dp_log "POST /api/review-disprove failed (http ${JOBS_HTTP:-none}); the run is not recorded"; return 1; }
}

dp_review() {
  local repo="$1" pr="$2" head="$3" project="$4" wt="$5" base="$6" out="$7" left="$8" rid="$9"
  local root od mode model vb va max cap bud maxb minl t0 i=0 no kind prot cls loc o rs stop="" rc spend spent=0
  local cost costs_known=1 calls=0 fp p n m nf=0 nc=0 nd=0 nk=0 nu=0 nchk=0 rw=0 rwrc tail_note
  local lane actor
  root=$(_dp_root); od="${DP_DIR:-$wt.dp}"; lane=$(_dp_lane)
  actor=lead-review; [ "$lane" = conductor ] && actor=merge-conductor
  mode=$(dp_gate "$project")
  [ "$mode" != off ] || { printf 'skipped:off off 0\n'; return 0; }
  vb=$(_dp_verdict "$out" BLOCK)
  [ "$vb" = BLOCK ] || { printf 'skipped:not-block %s 0\n' "$mode"; return 0; }
  [ -n "$root" ] || { _dp_log "no harness root"; printf 'skipped:no-root %s 0\n' "$mode"; return 0; }
  model=$(model_for review-disprove "$project" 2>/dev/null 7>&- 8>&-) && [ -n "$model" ] \
    || { _dp_log "no review-disprove route; no call"; printf 'skipped:no-route %s 0\n' "$mode"; return 0; }
  [ -r "$root/prompts/lead-review.d/disprove.md" ] \
    || { _dp_log "prompts/lead-review.d/disprove.md missing; no call"; printf 'skipped:no-prompt %s 0\n' "$mode"; return 0; }
  rm -rf "$od"; mkdir -p "$od" || { printf 'skipped:no-root %s 0\n' "$mode"; return 0; }
  dp_extract "$out" > "$od/findings.tsv"
  awk -F'\t' '$2 != "skip"' "$od/findings.tsv" > "$od/model.tsv"
  [ -s "$od/model.tsv" ] || { _dp_log "$repo#$pr: no model BLOCK finding; no call"; printf 'skipped:no-finding %s 0\n' "$mode"; return 0; }
  max=$(_dp_int max_findings 1 20 5)                # review.disprove.max_findings
  cap=$(_dp_usd usd_cap_day 50 2)                    # review.disprove.usd_cap_day
  bud=$(_dp_usd call_budget_usd 5 0.50)              # review.disprove.call_budget_usd
  maxb=$(_dp_int max_context_bytes 2000 200000 24000)  # review.disprove.max_context_bytes
  minl=$(_dp_int min_left_s 30 3600 120)             # review.disprove.min_left_s
  [[ "$left" =~ ^[0-9]+$ ]] || left=0
  t0=$SECONDS; : > "$od/outcomes.tsv"
  while IFS=$'\t' read -r no kind prot cls loc; do
    nf=$((nf + 1)); rs=""
    if [ "$kind" = noloc ]; then o=unchecked:no-loc
    elif [ "$i" -ge "$max" ]; then o=unchecked:cap
    elif [ -n "$stop" ]; then o="unchecked:$stop"
    elif [ "$((left - (SECONDS - t0)))" -lt "$minl" ]; then stop=time; o=unchecked:time
    elif ! command -v llm_gate_spend_today >/dev/null 2>&1 || ! spend=$(llm_gate_spend_today disprove 2>/dev/null 7>&- 8>&-) \
         || ! [[ "$spend" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then stop=spend-unknown; o=unchecked:spend-unknown
    elif ! awk -v s="$spend" -v h="$spent" -v b="$bud" -v c="$cap" 'BEGIN { exit !(s + h + b <= c) }'; then stop=cap; o=unchecked:cap
    else
      i=$((i + 1)); p="${loc%:*}"; n="${loc##*:}"; m="${n#*-}"; n="${n%-*}"
      { cat "$root/prompts/lead-review.d/disprove.md"
        printf '\n## Finding\n\n%s\n\n' "$(sed -n "${no}p" "$out" | tr -d '\r')"
        dp_context "$wt" "$base" "$head" "$p" "$n" "$m" "$maxb"; } > "$od/prompt.$i"
      if command -v lead_fp >/dev/null 2>&1; then
        fp=$(lead_fp "$repo" "$pr" "$head" "dp$(sed -n "${no}p" "$out" | sha256sum | cut -c1-12)")
      else fp="lead:$repo#$pr@$head~dp$(sed -n "${no}p" "$out" | sha256sum | cut -c1-12)"; fi
      rc=0; rm -f "$od/answer.$i" "$od/answer.$i.json"
      AGENT_CALL_NO_TOOLS=1 AGENT_CALL_BUDGET_USD="$bud" AGENT_CALL_GUARD_STAGE=lead-head AGENT_CALL_FP="$fp" AGENT_CALL_ROW_NOTE=disprove \
      AGENT_CALL_PR="https://github.com/$repo/pull/$pr" AGENT_CALL_ROLE=review-disprove "$root/bin/agent-call.sh" disprove "$project" "$model" "$((left - (SECONDS - t0)))" "$od/answer.$i" "@$od/prompt.$i" \
        >/dev/null 2>&1 7>&- 8>&- || rc=$?
      if [ "$rc" -ge 74 ] && [ "$rc" -le 79 ]; then o=unchecked:refused; rs="agent-call refused (rc $rc, nothing billed)"
      else
        calls=$((calls + 1)); cost=$(jq -r '.total_cost_usd // empty' "$od/answer.$i.json" 2>/dev/null)
        if [[ "$cost" =~ ^[0-9]+(\.[0-9]+)?([eE]-?[0-9]+)?$ ]]; then printf '%s\n' "$cost" >> "$od/costs"
          spent=$(awk -v a="$spent" -v b="$cost" 'BEGIN { printf "%.6f", a + b }')
        else costs_known=0; spent=$(awk -v a="$spent" -v b="$bud" 'BEGIN { printf "%.6f", a + b }'); fi
        if [ "$rc" != 0 ]; then o=failed; rs="agent-call rc $rc"
        elif ! grep -q '[^[:space:]]' "$od/answer.$i" 2>/dev/null; then o=failed; rs="empty answer"
        else IFS=$'\t' read -r o rs < <(dp_parse_answer "$od/answer.$i" "$wt" "$head")
          [ "$o" = DISPROVED ] && [ "$prot" = 1 ] && o=KEPT
        fi
      fi
    fi
    case "$o" in CONFIRMED|failed) nc=$((nc + 1)) ;; DISPROVED) nd=$((nd + 1)) ;; KEPT) nk=$((nk + 1)) ;; *) nu=$((nu + 1)) ;; esac
    case "$o" in CONFIRMED|DISPROVED|KEPT|failed) nchk=$((nchk + 1)) ;; esac
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$no" "$o" "$prot" "$cls" "$loc" "$rs" >> "$od/outcomes.tsv"
  done < "$od/model.tsv"
  [ "$stop" = cap ] && _dp_log "$repo#$pr: review.disprove.usd_cap_day ($cap USD) reached; the rest count as confirmed"
  va="$vb"; tail_note=""
  if [ "$mode" = enforce ]; then
    rwrc=0; dp_rewrite "$out" "$od/outcomes.tsv" || rwrc=$?
    case "$rwrc" in
      0) rw=1; va=$(_dp_verdict "$out" unknown) ;;
      3) tail_note=" (the rewrite left no readable verdict; the BLOCK stands)"; _dp_log "$repo#$pr: the rewrite left no readable verdict; restored" ;;
    esac
  else tail_note=" (shadow: unchanged)"; fi
  if [ "$costs_known" = 1 ]; then cost=$(awk '{ s += $1 } END { printf "%.6g", s + 0 }' "$od/costs" 2>/dev/null || printf 0)
    [ -n "$cost" ] || cost=0
  else cost=null; fi
  { printf -- '- disprove (BH-9047): mode %s; %s finding(s): %s confirmed, %s disproved, %s kept (protected), %s unchecked; verdict %s -> %s%s\n' \
      "$mode" "$nf" "$nc" "$nd" "$nk" "$nu" "$vb" "$va" "$tail_note"
    while IFS=$'\t' read -r no o prot cls loc rs; do
      printf '  - disprove %s %s %s: %s\n' "$o" "$cls" "$loc" "$(printf '%s' "${rs:-no reason}" | tr -d '[]`\r' | head -c 300)"
    done < "$od/outcomes.tsv"; } > "$od/report"
  jq -cRn --arg repo "$repo" --argjson pr "$pr" --arg sha "$head" --arg rid "$rid" --arg project "$project" --arg mode "$mode" \
    --arg vb "$vb" --arg va "$va" --argjson nf "$nf" --argjson nchk "$nchk" --argjson nc "$nc" --argjson nd "$nd" --argjson nk "$nk" \
    --argjson nu "$nu" --argjson cost "$cost" --arg lane "$lane" --arg actor "$actor" '
    { repo: $repo, pr: $pr, head_sha: $sha, review_id: $rid, lane: $lane, project: $project, mode: $mode,
      verdict_before: $vb, verdict_after: $va, findings: $nf, checked: $nchk, confirmed: $nc, disproved: $nd,
      kept_protected: $nk, unchecked: $nu, cost_usd: $cost, actor: $actor,
      detail: ([inputs | split("\t") | {cls: .[3], loc: .[4], outcome: .[1], reason: ((.[5] // "")[0:300])}][0:20]) }' \
    < "$od/outcomes.tsv" > "$od/record.json" 2>/dev/null \
    || { _dp_log "$repo#$pr: could not build the record"; : > "$od/record.json"; }
  [ -s "$od/record.json" ] && dp_record "$od/record.json"
  _dp_log "$repo#$pr @${head:0:12}: mode $mode, $nf finding(s), $calls call(s): $nc confirmed, $nd disproved, $nk kept, $nu unchecked; verdict $vb -> $va"
  printf 'ran %s %s\n' "$mode" "$rw"
}

# ── the conductor lane (BH-9047 C1) ──────────────────────────────────────────
# mc_rereview (bin/lib/mc/rebase.sh) sources this file in a subshell, with
# HARNESS set to the conductor's root, and calls the two functions below.

# _dpc_load — the libs dp_review reads, each only when its function is not
# already defined. rc 1 when one is missing.
_dpc_load() {
  local root; root=$(_dp_root); [ -n "$root" ] || return 1
  { command -v _jobs_req >/dev/null 2>&1 && command -v setting_get >/dev/null 2>&1; } \
    || { [ -r "$root/bin/jobs-client.sh" ] && . "$root/bin/jobs-client.sh"; } || return 1
  command -v model_for >/dev/null 2>&1 || { [ -r "$root/bin/lib/model-route.sh" ] && . "$root/bin/lib/model-route.sh"; } || return 1
  command -v llm_gate_spend_today >/dev/null 2>&1 || { [ -r "$root/bin/lib/llm-gate.sh" ] && . "$root/bin/lib/llm-gate.sh"; } || return 1
  command -v lead_fp >/dev/null 2>&1 || { [ -r "$root/bin/lib/review-bought.sh" ] && . "$root/bin/lib/review-bought.sh"; } || return 1
  command -v verdict_parse >/dev/null 2>&1 || { [ -r "$root/bin/lib/verdict-parse.sh" ] && . "$root/bin/lib/verdict-parse.sh"; } || return 1
  command -v _jobs_req >/dev/null 2>&1 && command -v setting_get >/dev/null 2>&1 && command -v model_for >/dev/null 2>&1 \
    && command -v llm_gate_spend_today >/dev/null 2>&1 && command -v verdict_parse >/dev/null 2>&1
}

# dpc_gate_on <project> — rc 0 when dp_gate <project> is shadow or enforce.
# The jobs client loads in a subshell; no root or no client is off.
dpc_gate_on() {
  local m
  m=$( { command -v _jobs_req >/dev/null 2>&1 && command -v setting_get >/dev/null 2>&1; } \
         || { r=$(_dp_root); [ -n "$r" ] && [ -r "$r/bin/jobs-client.sh" ] && . "$r/bin/jobs-client.sh"; } >/dev/null 2>&1 \
         || { printf off; exit 0; }
       dp_gate "$1" ) 2>/dev/null
  [ "$m" = shadow ] || [ "$m" = enforce ]
}

# dpc_run <slug> <num> <project> <head> <out> <review-id> — the disprove pass
# on a conductor re-review BLOCK. Prints ONE line `<result> <mode> <rewrote>`
# (dp_review's line, or skipped:<off|not-block|no-root|no-lib|no-finding|
# no-checkout>). The checkout is mc_patch_wt's (the hub clone of the project);
# origin main and <head> are fetched, the changed files' blobs are read once
# (a partial clone), and mc_git_auth_clear runs on every path after
# mc_patch_wt. The hunk base is main. In enforce, when <out> was
# rewritten, the report lines go above its last VERDICT line. <out>.dp is
# removed at the end; the D1 row and the caller's log line are the record.
dpc_run() {
  local slug="$1" num="$2" project="$3" head="$4" out="$5" rid="$6"
  ( local root od mode res r m w left vb
    root=$(_dp_root); [ -n "$root" ] || { echo "skipped:no-root off 0"; exit 0; }
    case "$out" in /*) ;; *) out="$PWD/$out" ;; esac
    od="$out.dp"
    _dpc_load >/dev/null 2>&1 || { echo "skipped:no-lib off 0"; exit 0; }
    command -v log >/dev/null 2>&1 || log() { if command -v mc_log >/dev/null 2>&1; then mc_log "$*"; else printf '%s\n' "$*" >&2; fi; }
    export DP_LANE=conductor DP_DIR="$od"
    mode=$(dp_gate "$project")
    [ "$mode" != off ] || { echo "skipped:off off 0"; exit 0; }
    [ "$(_dp_verdict "$out" BLOCK)" = BLOCK ] || { echo "skipped:not-block $mode 0"; exit 0; }
    # No model finding: no fetch, no call (dp_review would say the same).
    dp_extract "$out" | awk -F'\t' '$2 != "skip"' | grep -q . || { echo "skipped:no-finding $mode 0"; exit 0; }
    command -v mc_patch_wt >/dev/null 2>&1 || { echo "skipped:no-checkout $mode 0"; exit 0; }
    if ! mc_patch_wt "$slug" "$project" >/dev/null 2>&1 || [ -z "${MC_PATCH_WT:-}" ]; then
      command -v mc_git_auth_clear >/dev/null 2>&1 && mc_git_auth_clear
      echo "skipped:no-checkout $mode 0"; exit 0
    fi
    if ! git -C "$MC_PATCH_WT" -c credential.helper= fetch -q origin main "$head" >/dev/null 2>&1; then
      command -v mc_git_auth_clear >/dev/null 2>&1 && mc_git_auth_clear
      echo "skipped:no-checkout $mode 0"; exit 0
    fi
    # A --filter=blob:none clone (mc_patch_wt with no /root/repos/<project>)
    # holds no blobs: read the diff once while origin still has its credential,
    # so the changed files' blobs on both sides are local (BH-9047 r8). A path
    # outside the diff stays unread; its finding fails closed to CONFIRMED.
    git -C "$MC_PATCH_WT" -c credential.helper= diff "origin/main...$head" >/dev/null 2>&1 || true
    command -v mc_git_auth_clear >/dev/null 2>&1 && mc_git_auth_clear
    left=$(_dp_int conductor_left_s 60 3600 900)   # review.disprove.conductor_left_s
    res=$(dp_review "$slug" "$num" "$head" "$project" "$MC_PATCH_WT" main "$out" "$left" "$rid" 7>&- 8>&- | tail -n 1)
    read -r r m w <<<"$res"
    if [ "$w" = 1 ] && [ -s "$od/report" ]; then
      vb=$(_dp_verdict "$out" unknown)
      awk -v rep="$od/report" -v last="$(awk '/^[*]*VERDICT:/ { l = NR } END { print l + 0 }' "$out")" \
        'NR == last { while ((getline x < rep) > 0) print x; print "" } { print }' "$out" > "$out.dpins" \
        && cp -f "$out" "$out.dpprev" && mv -f "$out.dpins" "$out"
      # The report lines must not change the verdict the rewrite left.
      if [ -f "$out.dpprev" ] && [ "$(_dp_verdict "$out" unknown)" != "$vb" ]; then mv -f "$out.dpprev" "$out"; fi
      rm -f "$out.dpins" "$out.dpprev"
    fi
    rm -rf "$od"
    printf '%s\n' "${res:-skipped:error $mode 0}" )
}
