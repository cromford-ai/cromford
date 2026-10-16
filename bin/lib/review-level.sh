#!/bin/bash
# bin/lib/review-level.sh — review strictness scales to user impact (BH-7123).
# Sourced, never executed. The root is ${HARNESS:-${H:-}} or the sibling of
# this file's bin/.
#
# WHY. Every reviewer in the harness was binary: a finding about 2 px of padding
# and a finding about a cross-company read both became REQUEST_CHANGES / BLOCK,
# the same fix round, the same rebuild. Over 2026-09-25..10-16, 545 of 713
# BLOCK findings on project-6 and project-5 were below the bar a real user
# would notice, and 63 of 153 BLOCK verdicts (one rebuild+review+CI round each)
# held nothing that met it (docs/REVIEW_SEVERITY_AUDIT_2026-10-16.html).
#
# WHAT. Three pieces, all read from settings rows (see
# worker/jobs/schema.d/202610161737-bh-7123-review-levels.sql):
#   rl_mode <project>     strict | shadow | levels | cowboy | off
#   rl_prompt_note <p>    the `## Review level` text a lane appends to its prompt
#   rl_cap <file> <p> --approve W --block W [--lens inbuild|prs|lead]
#                         THE DEMOTER. Rewrites the review in place: a finding
#                         tagged BLOCK/HIGH/MEDIUM/... that names no ALWAYS-BLOCK
#                         class (catalog/review-always-block.tsv) and matches no
#                         class ERE becomes `[NOTE demoted ...]`; a NEEDS_HUMAN
#                         ask that is not a go-live step (catalog/review-golive.tsv)
#                         becomes `NOTE not verified here:`; when a demotion left
#                         no BLOCK standing, the final VERDICT line's block word
#                         becomes the approve word. A review in which nothing
#                         was demoted is NOT touched (byte-identical, no marker):
#                         a verdict with no recognisable finding lines is the
#                         model's to make. shadow logs `WOULD` and changes
#                         nothing; strict changes nothing. Idempotent: a file
#                         that carries the `Review level (BH-7123)` line is read,
#                         not rewritten. Prints
#                         `mode=M demoted=K standing=S verdict=V untagged=U`.
#                         rc 0 rewritten or nothing to do; rc 1 strict/shadow;
#                         rc 2 unreadable file or bad arguments.
# THE GRAMMAR GUARD. A keyword net cannot tell "shows the wrong text when the
# agent is Off" (a real bug) from "the Live step reads 'changed'" (a nit); only
# the reviewer can, by its `[BLOCK <class>]` tag. So an untagged BLOCK-word
# line is demoted only when it is known noise (catalog/review-nits.tsv) OR the
# final round carries at least one class tag (the model used the grammar). A
# review that never names a class keeps its untagged BLOCKs: today's behaviour
# minus the known noise, never a silent merge of a real bug. `[NOTE]` alone is
# not grammar evidence: the lead lane wrote `[BLOCK]`/`[NOTE]` long before the
# classes existed. The ALWAYS-BLOCK floor never demotes, in any mode, off
# included: `off` is a merge-gate switch for wave B, and here it reads as levels.
# shellcheck shell=bash

_rl_root() {
  local r="${HARNESS:-${H:-}}"
  [ -n "$r" ] && [ -d "$r/catalog" ] && { printf '%s' "$r"; return 0; }
  r=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd) || return 1
  printf '%s' "$r"
}

# rl_knob <base> <project> <default> <ere> — the row `<base>.<project>`, then
# `<base>`, then the default. A value that does not match <ere> is logged and
# the default is used. rc 2 from setting_get (no row) falls through; rc 1 (an
# outage) is fail-open to the default on purpose: a blip must never tighten or
# loosen a review by itself. REVIEW_LEVEL_<BASE-UPPER-SNAKE> in the env wins
# over everything (tests, a one-off lane run). Memoised per process and key:
# a review of 100 lines must not ask the worker 100 times (bash 3.2 safe: no
# associative arrays, the memo is one variable per key).
rl_knob() {
  local base="$1" p="${2:-}" def="$3" re="${4:-.*}" k v rc envk memo
  envk="REVIEW_LEVEL_$(printf '%s' "${base#review.}" | tr '[:lower:].-' '[:upper:]__')"
  v="${!envk:-}"
  if [ -n "$v" ]; then
    [[ "$v" =~ $re ]] && { printf '%s' "$v"; return 0; }
  fi
  memo="_RL_MEMO_$(printf '%s' "$base|$p|$def" | tr -c 'A-Za-z0-9' '_')"
  if [ -n "${!memo:-}" ]; then printf '%s' "${!memo}"; return 0; fi
  v="$def"
  if command -v setting_get >/dev/null 2>&1; then
    for k in ${p:+"$base.$p"} "$base"; do
      [ "${#k}" -le 64 ] || continue
      rc=0; v=$(setting_get "$k" 2>/dev/null 7>&- 8>&-) || rc=$?
      case "$rc" in
        0) v=$(printf '%s' "$v" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')
           if [[ "$v" =~ $re ]]; then break; fi
           echo "review-level: $k reads '$v', not $re; default $def" >&2
           v="$def"; break ;;
        2) v="$def"; continue ;;
        *) v="$def"; break ;;
      esac
    done
  fi
  printf -v "$memo" '%s' "$v"
  printf '%s' "$v"
}

rl_mode() { rl_knob review.mode "${1:-}" levels '^(strict|shadow|levels|cowboy|off)$'; }

# _rl_catalog_re <file> — the EREs of a catalog joined with |, comments dropped.
_rl_catalog_re() {
  local f="$1" line re="" ere
  [ -r "$f" ] || return 1
  while IFS= read -r line; do
    case "$line" in ''|'#'*) continue ;; esac
    ere=$(printf '%s' "$line" | awk -F'\t' '{print $2}')
    [ -n "$ere" ] || continue
    re="${re:+$re|}$ere"
  done < "$f"
  [ -n "$re" ] || return 1
  printf '%s' "$re"
}
_rl_catalog_classes() {
  local f="$1" line c out=""
  [ -r "$f" ] || return 1
  while IFS= read -r line; do
    case "$line" in ''|'#'*) continue ;; esac
    c=$(printf '%s' "$line" | awk -F'\t' '{print $1}')
    [ -n "$c" ] && out="${out:+$out|}$c"
  done < "$f"
  printf '%s' "$out"
}
# The catalogs are read once per process (rl_catalogs_load) and again only
# when the root changes; the rl_line_* readers below use the loaded values.
_RL_LOADED_ROOT=""; _RL_ALWAYS_RE=""; _RL_CLASSES=""; _RL_NIT_RE=""; _RL_GOLIVE_RE=""
rl_catalogs_load() {
  local root; root=$(_rl_root) || return 1
  [ "$_RL_LOADED_ROOT" = "$root" ] && [ -n "$_RL_ALWAYS_RE" ] && return 0
  _RL_ALWAYS_RE=$(_rl_catalog_re "$root/catalog/review-always-block.tsv") || _RL_ALWAYS_RE=""
  _RL_CLASSES=$(_rl_catalog_classes "$root/catalog/review-always-block.tsv") || _RL_CLASSES=""
  _RL_NIT_RE=$(_rl_catalog_re "$root/catalog/review-nits.tsv") || _RL_NIT_RE=""
  _RL_GOLIVE_RE=$(_rl_catalog_re "$root/catalog/review-golive.tsv") || _RL_GOLIVE_RE=""
  _RL_LOADED_ROOT="$root"
  return 0
}
rl_always_re()      { rl_catalogs_load || return 1; [ -n "$_RL_ALWAYS_RE" ] && printf '%s' "$_RL_ALWAYS_RE"; }
rl_always_classes() { rl_catalogs_load || return 1; printf '%s' "$_RL_CLASSES"; }
rl_nit_re()         { rl_catalogs_load || return 1; [ -n "$_RL_NIT_RE" ] && printf '%s' "$_RL_NIT_RE"; }
rl_golive_re()      { rl_catalogs_load || return 1; [ -n "$_RL_GOLIVE_RE" ] && printf '%s' "$_RL_GOLIVE_RE"; }

# A finding line: a list marker or number, optional bold/bracket, then a
# severity word. `**[HIGH]**`, `- [BLOCK] path`, `1. **BLOCK (speed claim…)**`,
# `[BLOCKING — no dead rows]`, `[blocker]`, `[major]` all match.
RL_FIND_RE='^[[:space:]]*([-*]|[0-9]+[.)])?[[:space:]]*(\*\*)?\[?(BLOCK|BLOCKING|BLOCKER|HIGH|MEDIUM|MAJOR|CRITICAL|LOW|MINOR|NIT)([]:[:space:](—-]|\*\*|$)'
# The words that mean "this stops the merge" to a reader; LOW/MINOR/NIT do not.
RL_BLOCKWORD_RE='\[?(BLOCK|BLOCKING|BLOCKER|HIGH|MEDIUM|MAJOR|CRITICAL)([]:[:space:](—-]|\*\*|$)'
# A class tag: `[BLOCK tenant-leak]`, `[BLOCK: money]`, `[BLOCKER — red-build]`.
_rl_class_tag_re() { local c; c=$(rl_always_classes) || return 1; [ -n "$c" ] || return 1; printf '\\[(BLOCK|BLOCKING|BLOCKER)[[:space:]:—-]+(%s)\\]' "$c"; }

# rl_line_blocks <line> — rc 0 when the finding line stands as a BLOCK: its tag
# names an ALWAYS-BLOCK class, or its text matches a class ERE. Reads come from
# here-strings, never a printf pipe (a grep -q on a pipe races SIGPIPE, BH-6109).
rl_line_blocks() {
  local line="$1" tagre always
  rl_catalogs_load || return 1
  [ -n "$_RL_ALWAYS_RE" ] || return 1
  if tagre=$(_rl_class_tag_re); then grep -qiE "$tagre" <<<"$line" && return 0; fi
  always="$_RL_ALWAYS_RE"
  grep -qiE "$always" <<<"$line"
}
# rl_line_golive <line> — rc 0 when a human ask is a go-live step.
rl_line_golive() { rl_catalogs_load || return 1; [ -n "$_RL_GOLIVE_RE" ] || return 1; grep -qiE "$_RL_GOLIVE_RE" <<<"$1"; }
# rl_line_nit <line> — rc 0 when the finding is known review noise.
rl_line_nit()    { rl_catalogs_load || return 1; [ -n "$_RL_NIT_RE" ] || return 1; grep -qiE "$_RL_NIT_RE" <<<"$1"; }

# rl_prompt_note <project> — the `## Review level` section for a prompt.
rl_prompt_note() {
  local p="${1:-}" mode ms pct flows
  mode=$(rl_mode "$p")
  ms=$(rl_knob review.perf_block_ms "$p" 300 '^[0-9]{1,6}$')
  pct=$(rl_knob review.perf_block_stmt_pct "$p" 20 '^[0-9]{1,3}$')
  flows=$(rl_knob review.core_flows "$p" "" '.*')
  printf '\n## Review level (BH-7123)\nmode: %s. Tag every finding [BLOCK <class>] (class from the ALWAYS-BLOCK list in the REVIEW LEVELS rule) or [NOTE]; a review whose findings are all [NOTE] approves. Speed: a BLOCK only for a measured regression on a key screen over %s ms or over %s%% more DB statements, or on a perf ticket. Core flows of this project%s: %s.\n' \
    "$mode" "$ms" "$pct" "${p:+ ($p)}" "${flows:-none listed; review at smoke level}"
}

# _rl_last_verdict_ln <file> <words-ere> — the line number of the LAST anchored
# verdict line (bin/lib/verdict-parse.sh's anchor: label at line start, optional
# markdown bold/heading, optional colon, then the word).
_rl_last_verdict_ln() {
  grep -niE "^[[:space:]]*(#+[[:space:]]*)?(\*\*)?verdict(\*\*)?:?[[:space:]]*(\*\*)?($2)(\*\*)?[[:space:]]*$" "$1" 2>/dev/null | tail -1 | cut -d: -f1
}
# _rl_final_start <file> — the first line of the final round (after the last
# `=== ` header review.sh writes before a merged re-review), else 0.
_rl_final_start() {
  local n; n=$(grep -n '^=== ' "$1" 2>/dev/null | tail -1 | cut -d: -f1)
  printf '%s' "${n:-0}"
}

# rl_cap <file> <project> --approve WORD --block WORD [--lens inbuild|prs|lead]
rl_cap() {
  local f="${1:-}" p="${2:-}" aw="" bw="" lens="inbuild" mode start n k=0 s=0 u=0 line newl vln vword marker tmp tagre grammar=0 final
  shift 2 2>/dev/null || true
  while [ $# -gt 0 ]; do
    case "$1" in
      --approve) aw="${2:-}"; shift 2 ;;
      --block) bw="${2:-}"; shift 2 ;;
      --lens) lens="${2:-inbuild}"; shift 2 ;;
      *) shift ;;
    esac
  done
  [ -n "$f" ] && [ -r "$f" ] && [ -n "$aw" ] && [ -n "$bw" ] || return 2
  mode=$(rl_mode "$p")
  if grep -q '^Review level (BH-7123):' "$f" 2>/dev/null; then
    # Already capped: answer from the marker line, change nothing.
    sed -nE 's/^Review level \(BH-7123\): mode ([a-z]+), ([0-9]+) finding\(s\) demoted to NOTE, ([0-9]+) BLOCK stands; verdict ([A-Za-z_-]+)\..*/mode=\1 demoted=\2 standing=\3 verdict=\4 untagged=0/p' "$f" | tail -1
    return 0
  fi
  case "$mode" in strict) printf 'mode=strict demoted=0 standing=0 verdict=unchanged untagged=0\n'; return 1 ;; esac
  rl_catalogs_load || return 2
  start=$(_rl_final_start "$f")
  vln=$(_rl_last_verdict_ln "$f" "$aw|$bw")
  vword=""
  [ -n "$vln" ] && vword=$(sed -n "${vln}p" "$f" | grep -oiE "($aw|$bw)" | tail -1 | tr '[:lower:]' '[:upper:]')
  # The grammar guard: a class tag anywhere in the final round.
  final=$(tail -n +"$((start+1))" "$f")
  if tagre=$(_rl_class_tag_re) && grep -qiE "$tagre" <<<"$final"; then grammar=1; fi
  tmp=$(mktemp "${TMPDIR:-/tmp}/rl-cap.XXXXXX") || return 2
  n=0
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n+1))
    if [ "$n" -le "$start" ] || { [ -n "$vln" ] && [ "$n" -ge "$vln" ]; }; then
      printf '%s\n' "$line" >> "$tmp"; continue
    fi
    # A go-live human ask stands (and keeps its NEEDS_HUMAN: line for the hold).
    if grep -qE '^[[:space:]]*NEEDS_HUMAN:[[:space:]]*[^[:space:]]' <<<"$line"; then
      if rl_line_golive "$line"; then s=$((s+1)); printf '%s\n' "$line" >> "$tmp"
      else k=$((k+1)); sed -E 's/^([[:space:]]*)NEEDS_HUMAN:[[:space:]]*/\1NOTE not verified here (demoted, BH-7123): /' <<<"$line" >> "$tmp"
      fi
      continue
    fi
    if grep -qiE "$RL_FIND_RE" <<<"$line"; then
      if grep -qiE "\[BLOCK needs-human\]" <<<"$line"; then
        if rl_line_golive "$line"; then s=$((s+1)); printf '%s\n' "$line" >> "$tmp"
        else k=$((k+1)); sed -E 's/\[BLOCK needs-human\]/[NOTE not verified here, demoted from BLOCK needs-human]/' <<<"$line" >> "$tmp"
        fi
        continue
      fi
      # A finding on the ALWAYS-BLOCK floor stands whatever its tag: a tenant
      # leak the model called [LOW] (project-6#289) keeps the verdict BLOCK.
      if rl_line_blocks "$line"; then
        s=$((s+1)); printf '%s\n' "$line" >> "$tmp"; continue
      fi
      if grep -qiE "^[[:space:]]*([-*]|[0-9]+[.)])?[[:space:]]*(\*\*)?$RL_BLOCKWORD_RE" <<<"$line"; then
        if [ "$grammar" = 0 ] && ! rl_line_nit "$line"; then
          # Untagged, not known noise, and the model never used a class tag:
          # it stands, and is counted so the log shows how often this happens.
          s=$((s+1)); u=$((u+1)); printf '%s\n' "$line" >> "$tmp"; continue
        fi
        k=$((k+1))
        # Rewrite the first severity tag: `[HIGH]` -> `[NOTE demoted from HIGH]`,
        # `BLOCK (x)` -> `NOTE demoted from BLOCK (x)`, `[BLOCK — no dead rows]`
        # -> `[NOTE demoted from BLOCK — no dead rows]`.
        newl=$(sed -E 's/^([[:space:]]*([-*]|[0-9]+[.)])?[[:space:]]*(\*\*)?\[?)(BLOCKING|BLOCKER|BLOCK|HIGH|MEDIUM|MAJOR|CRITICAL)/\1NOTE demoted from \4/I' <<<"$line")
        printf '%s\n' "$newl" >> "$tmp"
        continue
      fi
    fi
    printf '%s\n' "$line" >> "$tmp"
  done < "$f"
  if [ "$k" = 0 ]; then
    # Nothing to demote: the file is the model's answer, byte for byte.
    rm -f "$tmp"
    printf 'mode=%s demoted=0 standing=%s verdict=%s untagged=%s\n' "$mode" "$s" "${vword:-unknown}" "$u"
    return 0
  fi
  if [ "$mode" = shadow ]; then
    rm -f "$tmp"
    echo "review-level: WOULD demote $k finding(s), $s standing, verdict ${vword:-unknown}$([ "$s" = 0 ] && [ "$vword" = "$bw" ] && printf ' -> %s' "$aw") (shadow, $lens)" >&2
    printf 'mode=shadow demoted=%s standing=%s verdict=%s untagged=%s\n' "$k" "$s" "${vword:-unknown}" "$u"
    return 1
  fi
  if [ "$s" = 0 ] && [ -n "$vln" ] && [ "$vword" = "$bw" ]; then
    # The final VERDICT line's block word becomes the approve word, case kept
    # upper. Nothing else on the line changes.
    sed -i.rlbak -E "${vln}s/$bw/$aw/" "$tmp" 2>/dev/null || sed -i '' -E "${vln}s/$bw/$aw/" "$tmp"
    rm -f "$tmp.rlbak"
    vword="$aw"
  fi
  marker="Review level (BH-7123): mode $mode, $k finding(s) demoted to NOTE, $s BLOCK stands; verdict ${vword:-unknown}."
  [ "$u" = 0 ] || marker="$marker $u untagged finding(s) kept (grammar not used)."
  if [ -n "$vln" ]; then
    # The marker sits right above the verdict block (TIER:/VERDICT:), never after it.
    awk -v ln="$vln" -v m="$marker" 'NR==ln{ if (prev !~ /^[[:space:]]*TIER/) print m } {print; prev=$0}' "$tmp" > "$tmp.2" && mv -f "$tmp.2" "$tmp"
    if ! grep -qF "$marker" "$tmp"; then
      awk -v ln="$((vln-1))" -v m="$marker" 'NR==ln{print m} {print}' "$tmp" > "$tmp.2" && mv -f "$tmp.2" "$tmp"
    fi
  else
    printf '%s\n' "$marker" >> "$tmp"
  fi
  cat "$tmp" > "$f" && rm -f "$tmp" || { rm -f "$tmp"; return 2; }
  printf 'mode=%s demoted=%s standing=%s verdict=%s untagged=%s\n' "$mode" "$k" "$s" "${vword:-unknown}" "$u"
  return 0
}
