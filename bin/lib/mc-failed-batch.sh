# shellcheck shell=bash
# bin/lib/mc-failed-batch.sh — A BATCH FAILURE STAYS WITH ITS PATCH, NOT ONLY
# WITH ITS SHA (BH-8186). Sourced by bin/merge-conductor.d/bh-8186-failed-batch.sh,
# never executed. No side effect at source time.
#
# WHY (2026-10-23). Mergify dequeued #8127 at 14:06Z with
# BATCH_MAX_FAILURE_RESOLUTION_ATTEMPTS at 3b036d00. At 15:43Z the harness
# rebased it to 653fca8a: the same patch on a new sha. Every failure mark the
# conductor keeps is keyed on the sha (`ejected`, `dqwculprit`, `reejected`,
# `bejv`), but the approval follows the patch (rebind_patch_id). So the new sha
# was READY with no failure on it, and at 19:02Z the READY arm enqueued it
# again. #8128 did the same. Both dragged #8105's batch.
#
# THE RECORD. $MC_STATE_DIR/failed-batch/<owner_repo>_<num>, append-only TSV,
# the last MC_FAILED_BATCH_KEEP_LINES lines kept (fallback 20; the ec_record shape):
#   <epoch> <head> <patch-id|-> <word> <code|-> <draft|-> <checks|->
# <word> is failed, pending (the dequeue read failed; the hold reads again) or
# cleared:<why> (new-patch, bystander, window, not-counted). The newest
# failed/pending line is the live record, unless a cleared line comes after it.
# Checks are %-encoded (space, comma, percent) and comma-joined.
#
# Pure functions take no clock and make no network call: callers pass the epoch.

FBH_PAYLOAD_RE='-\*- Mergify Payload -\*-(?<p>[\s\S]*?)-\*- Mergify Payload End -\*-'

# fbh_now — epoch seconds. MC_FAILED_BATCH_NOW pins it (the test clock seam).
fbh_now() {
  case "${MC_FAILED_BATCH_NOW:-}" in ''|*[!0-9]*) date -u +%s ;; *) printf '%s' "$MC_FAILED_BATCH_NOW" ;; esac
}

# _fbh_knob <ENV> <default> — a merge-conductor lane knob as a string: the
#   settings row lane.merge-conductor.<env lower> through lane_knob, else the
#   env var, else <default> (the documented fallback).
_fbh_knob() {
  local v=""
  if command -v lane_knob >/dev/null 2>&1; then v=$(lane_knob merge-conductor "$1" "${P:-}" 2>/dev/null); fi
  [ -n "$v" ] || v="${!1:-}"
  [ -n "$v" ] || v="$2"
  printf '%s' "$v"
}

# fbh_enabled — rc 0 unless MC_FAILED_BATCH is 0 (fallback 1; row
#   lane.merge-conductor.mc_failed_batch).
fbh_enabled() { [ "$(_fbh_knob MC_FAILED_BATCH 1)" != 0 ]; }

# fbh_window_s — MC_FAILED_BATCH_UNJUDGED_HOLD_S, the longest hold of a record
#   no proof judges (fallback 86400; row
#   lane.merge-conductor.mc_failed_batch_unjudged_hold_s).
fbh_window_s() {
  local v; v=$(_fbh_knob MC_FAILED_BATCH_UNJUDGED_HOLD_S 86400)
  case "$v" in ''|*[!0-9]*) v=86400 ;; esac
  printf '%s' "$v"
}

# fbh_keep_days — MC_FAILED_BATCH_KEEP_DAYS, how long a record file is kept
#   (fallback 14; row lane.merge-conductor.mc_failed_batch_keep_days).
fbh_keep_days() {
  local v; v=$(_fbh_knob MC_FAILED_BATCH_KEEP_DAYS 14)
  case "$v" in ''|*[!0-9]*|0) v=14 ;; esac
  printf '%s' "$v"
}

# fbh_keep_lines — MC_FAILED_BATCH_KEEP_LINES, how many lines a record file
#   keeps (fallback 20; row lane.merge-conductor.mc_failed_batch_keep_lines).
fbh_keep_lines() {
  local v; v=$(_fbh_knob MC_FAILED_BATCH_KEEP_LINES 20)
  case "$v" in ''|*[!0-9]*|0|1) v=20 ;; esac
  printf '%s' "$v"
}

# fbh_gc_interval_min — MC_FAILED_BATCH_GC_INTERVAL_MIN, the least minutes
#   between two fbh_gc sweeps (fallback 60; row
#   lane.merge-conductor.mc_failed_batch_gc_interval_min).
fbh_gc_interval_min() {
  local v; v=$(_fbh_knob MC_FAILED_BATCH_GC_INTERVAL_MIN 60)
  case "$v" in ''|*[!0-9]*) v=60 ;; esac
  printf '%s' "$v"
}

# fbh_code_counts <code> — rc 0 when the dequeue code is in MC_FAILED_BATCH_CODES
#   (fallback CHECKS_FAILED,BATCH_MAX_FAILURE_RESOLUTION_ATTEMPTS; row
#   lane.merge-conductor.mc_failed_batch_codes).
fbh_code_counts() {
  local c="$1" codes
  [ -n "$c" ] && [ "$c" != - ] || return 1
  codes=$(_fbh_knob MC_FAILED_BATCH_CODES CHECKS_FAILED,BATCH_MAX_FAILURE_RESOLUTION_ATTEMPTS)
  case ",${codes// /}," in *",$c,"*) return 0 ;; esac
  return 1
}

# fbh_enc <text> / fbh_dec <text> — one check name as one word, and back.
fbh_enc() { local s="${1//%/%25}"; s="${s// /%20}"; s="${s//	/%09}"; printf '%s' "${s//,/%2C}"; }
fbh_dec() { local s="${1//%20/ }"; s="${s//%2C/,}"; s="${s//%09/	}"; printf '%s' "${s//%25/%}"; }

# fbh_checks_text <checks> — "a, b" for a reason.
fbh_checks_text() {
  local c out=""
  local -a cs
  [ -n "$1" ] && [ "$1" != - ] || { printf '%s' '-'; return 0; }
  IFS=, read -ra cs <<<"$1"
  for c in "${cs[@]}"; do out+="${out:+, }$(fbh_dec "$c")"; done
  printf '%s' "$out"
}

# fbh_parse <comments-json> — PURE.
#   -> "<code|->\t<left sha|->\t<draft|->\t<checks %-encoded, comma-joined|->"
#   rc 0 the NEWEST mergify[bot] payload comment, by (created_at, id) and never
#        by updated_at (Mergify edits old ones), has state `dequeued`
#   rc 1 there is no payload comment, or the newest one is not a dequeue
#   rc 2 the JSON could not be read
#   code: dequeue_reason.code. left sha: the last "Left the queue … at `<sha>`"
#   line. draft: the last "on draft #N". checks: dequeue_reason.checks (strings,
#   or objects with a name), else the "Failing checks:" bullets.
fbh_parse() {
  local raw="$1" line
  line=$(jq -r --arg re "$FBH_PAYLOAD_RE" '
    def enc: gsub("%"; "%25") | gsub(" "; "%20") | gsub("\t"; "%09") | gsub(","; "%2C");
    if type != "array" then error("not a comment list") else . end
    | [ .[] | select(type == "object" and (.user.login // "") == "mergify[bot]"
                     and ((.body // "") | type == "string") and ((.body // "") | test($re))) ]
    | sort_by([(.created_at // ""), (.id // 0)]) | last
    | if . == null then "NONE" else
        .body as $b
        | (($b | capture($re).p | fromjson?) // {}) as $p
        | if (($p | type) != "object") or (($p.state // "") != "dequeued") then "NONE" else
            (($p.dequeue_reason.code // "") | if type == "string" then . else "" end) as $code
            | ([$b | scan("Left the queue\\*\\*[^\\n]*? at `([0-9a-fA-F]{7,40})`")] | last // [""] | .[0] | ascii_downcase) as $s
            | ([$b | scan("on draft #([0-9]+)")] | last // [""] | .[0]) as $d
            | ([ ($p.dequeue_reason.checks // [])[]?
                 | if type == "string" then . elif type == "object" then (.name // "") else "" end
                 | select(. != "") ]) as $pc
            | (if ($pc | length) > 0 then $pc else
                 [ ($b | split("Failing checks:") | if length > 1 then (.[1] | split("\n## ") | .[0]) else "" end)
                   | split("\n")[] | select(test("^[[:space:]]*[-*] "))
                   | ((capture("`(?<c>[^`]+)`") | .c) // "") | select(. != "") ] end) as $cs
            | ([$cs[] | enc] | join(",")) as $c
            | [$code, $s, $d, $c] | map(if . == "" then "-" else . end) | @tsv
          end
      end' <<<"$raw" 2>/dev/null) || return 2
  [ -n "$line" ] || return 2
  [ "$line" = NONE ] && return 1
  printf '%s\n' "$line"
}

# fbh_file <owner/repo> <num> — the record path.
fbh_file() { printf '%s/failed-batch/%s_%s' "${MC_STATE_DIR:-/nonexistent}" "${1//\//_}" "$2"; }

# fbh_append <file> <epoch> <head> <patch-id> <word> <code> <draft> <checks>
#   One line, the last fbh_keep_lines kept; tmp + mv, so the mtime moves (the
#   gc reads it) and a reader never sees half a file. rc 1 = not written.
fbh_append() {
  local f="$1"; shift
  local a=() x
  for x in "$@"; do x="${x//	/ }"; x="${x//$'\n'/ }"; a+=("${x:--}"); done
  { mkdir -p "${f%/*}" \
    && { [ -r "$f" ] && tail -n $(( $(fbh_keep_lines) - 1 )) "$f"; printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "${a[@]:0:7}"; } > "$f.tmp.$$" \
    && mv -f "$f.tmp.$$" "$f"; } 2>/dev/null && return 0
  rm -f "$f.tmp.$$" 2>/dev/null
  return 1
}

# fbh_live <file> — the live record line (a failed or pending line with no
#   cleared line after it), or nothing.
fbh_live() {
  [ -s "$1" ] || return 0
  awk -F'\t' '$4 == "failed" || $4 == "pending" { live = $0; next }
              $4 ~ /^cleared:/ { live = "" }
              END { if (live != "") print live }' "$1" 2>/dev/null
}

# fbh_decide <same 0|1|?> <solo word|-> <age_s> <window_s> — PURE. One word:
#   clear:new-patch  a different patch (a real push)
#   wait             the patch could not be compared this tick
#   clear:bystander  the solo re-run passed: the failure was another PR's
#   hold-judged      the solo re-run reproduced the failure with this patch
#   hold             no verdict yet, inside the window
#   clear:window     no verdict, and the record is a whole window old
fbh_decide() {
  local same="$1" solo="${2:--}" age="${3:-0}" win="${4:-86400}"
  case "$age" in ''|*[!0-9]*) age=0 ;; esac
  case "$win" in ''|*[!0-9]*) win=86400 ;; esac
  case "$same" in
    0) echo clear:new-patch; return 0 ;;
    1) ;;
    *) echo wait; return 0 ;;
  esac
  case "$solo" in
    clean) echo clear:bystander ;;
    reproduces) echo hold-judged ;;
    *) if [ "$age" -ge "$win" ]; then echo clear:window; else echo hold; fi ;;
  esac
}

# fbh_gc — delete record files untouched for MC_FAILED_BATCH_KEEP_DAYS days.
#   At most once per fbh_gc_interval_min minutes (a stamp file). Prints the count it deleted.
fbh_gc() {
  local d="${MC_STATE_DIR:-}/failed-batch" st n
  [ -n "${MC_STATE_DIR:-}" ] && [ -d "$d" ] || { echo 0; return 0; }
  st="$d/.gc"
  if [ -e "$st" ] && [ -z "$(find "$st" -mmin +"$(fbh_gc_interval_min)" 2>/dev/null)" ]; then echo 0; return 0; fi
  : > "$st" 2>/dev/null
  n=$(find "$d" -maxdepth 1 -type f ! -name '.*' -mtime +"$(fbh_keep_days)" -print -delete 2>/dev/null | wc -l)
  echo "$((n + 0))"
}
