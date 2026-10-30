# shellcheck shell=bash
# bin/lib/lead-part-review.sh — BH-8533: the lead part-review mode.
#
# Sourced by bin/lead-review.sh through
# bin/lib/lead-review/libs.d/202610270120-bh-8533-lead-part-review.sh. Functions
# only, no set -e, no side effect at source. Needs the host's H, log, DEADLINE,
# MODE, gh_rest, lr_verdict, lr_pick_review, lr_rate_limited, lr_guard_spent,
# lead_fp (bin/lib/review-bought.sh), ldp_build (bin/lib/lead-diff-parts.sh) and
# the jobs client (job_ledger_row, job_ledger_put, job_artifact_put).
#
# A full review over LEAD_REVIEW_DIFF_MAX_BYTES that leaves a file unread used
# to be a split-required BLOCK with no model call. When the split that
# ldp_build proposes fits, the lane now reviews the SAME head in N parts: one
# paid call per part, each part a whole-file read under the part limit, then
# ONE aggregate verdict that goes through the host's usual post-processing and
# finish_done. Nothing merges unread: a missing, failed or stale part is no
# verdict, never MERGE.
#
#   lpr_plan <wt> <base-ref> <sha> <diff-max> <repo> <pr>
#       rc 0 = part mode: LPR_N parts, partition fingerprint LPR_PFP, and each
#       part's prompt tail (`## Part review` to the end of its diff) in
#       <wt>.ptail.<k>, each at or under the part limit.
#       rc 1 = no part mode; LPR_WHY says why (off, over LEAD_REVIEW_PART_MAX,
#       a unit over the limit alone, a coverage fault, a lib not loaded).
#   lpr_prompt <k> <common-prompt> <out>
#       the common prompt, then part k's tail.
#   lpr_run <project> <repo> <pr> <sha> <model> <common-prompt> <wt> <job> <key> <request-id>
#       the N paid calls, in order. Each part: live head read, the part ledger
#       (dedupe BEFORE spend), the call-guard peek, the deadline share, the
#       paid call, then the answer persisted (local file, ledger row, job
#       artifact) before the next part. Sets LPR_RC:
#         ok          LPR_OUT holds the aggregate, LPR_VERDICT its word
#         superseded  the PR closed or its head moved (LPR_DETAIL)
#         release     nothing billed for the part that stopped (LPR_DETAIL)
#         ratelimit   a rate or concurrency limit (LPR_DETAIL = the rc)
#         empty       a part had no readable verdict after one retry
#         lost        a part's guard key is paid with no stored answer
#   lpr_aggregate <out> — called by lpr_run once every part has a verdict.
#
# State. The ledger kind `lead_part`, key <repo>#<pr>@<sha>/p<k>of<N>/<pfp8>,
# status = the part's verdict word, detail = {request_id, part, of, model,
# path, body} (capped at 4000 UTF-16 units like lr_detail). The paid call's
# call-guard key is lead_fp <repo> <pr> <sha> p<k>of<N>x<pfp8> on stage
# lead-head (K=1); the no-verdict retry is p<k>of<N>n<pfp8>. The local copy is
# state/lead-reviews/parts/<owner_repo>-<pr>-<sha12>-p<k>of<N>.md.
#
# Knobs (catalog/lanes.d/lead-review.knobs.d/, settings rows
# lane.lead-review.lead_review_part_*):
#   LEAD_REVIEW_PART_REVIEW_ENABLED  1 = part mode (default); any other value = off
#   LEAD_REVIEW_PART_MAX             most parts per head (default 8, 2..20)
#   LEAD_REVIEW_PART_BYTES           part limit in bytes; 0 = LEAD_REVIEW_DIFF_MAX_BYTES
#   LEAD_REVIEW_PART_MIN_LEFT_S      least seconds a part call gets (default 60);
#                                    under it the claim is released, nothing billed

LPR_N=0 LPR_PFP="" LPR_WHY="" LPR_RC="" LPR_VERDICT="" LPR_OUT="" LPR_DETAIL="" LPR_SUM=""
LPR_ON=0 LPR_MAX=0 LPR_BYTES=0 LPR_LEFT_MIN=0 LPR_TSV="" LPR_WT=""

_lpr_log() { if command -v log >/dev/null 2>&1; then log "$*"; else echo "lead-part-review: $*" >&2; fi; }

# _lpr_int <env> <default> <min> <max> — the knob's integer value. Empty is the
#   default; a value that is not an integer in min..max is one log line and the default.
_lpr_int() {
  local v="${!1:-}"
  if [ -z "$v" ]; then printf '%s' "$2"; return 0; fi
  if [[ "$v" =~ ^[0-9]{1,9}$ ]] && [ "$((10#$v))" -ge "$3" ] && [ "$((10#$v))" -le "$4" ]; then
    printf '%s' "$((10#$v))"; return 0
  fi
  _lpr_log "$1='$v' is not an integer in $3..$4; using $2 (BH-8533)"
  printf '%s' "$2"
}

# lpr_knobs <diff-max> — LPR_ON, LPR_MAX, LPR_BYTES, LPR_LEFT_MIN. The code
#   fallbacks name the settings rows lane.lead-review.lead_review_part_review_enabled
#   (1), lane.lead-review.lead_review_part_max (8),
#   lane.lead-review.lead_review_part_bytes (0 = <diff-max>) and
#   lane.lead-review.lead_review_part_min_left_s (60, the floor bin/lead-review.sh
#   gives its single agent call).
lpr_knobs() {
  LPR_ON=0; [ "${LEAD_REVIEW_PART_REVIEW_ENABLED-1}" = 1 ] && LPR_ON=1
  LPR_MAX=$(_lpr_int LEAD_REVIEW_PART_MAX 8 2 20)
  LPR_BYTES=$(_lpr_int LEAD_REVIEW_PART_BYTES 0 0 600000)
  LPR_LEFT_MIN=$(_lpr_int LEAD_REVIEW_PART_MIN_LEFT_S 60 30 3600)
  [ "$LPR_BYTES" -gt 0 ] || LPR_BYTES="$1"
}

# _lpr_tail <k> <repo> <pr> <sha> <base> > file — part k's prompt tail.
_lpr_tail() {
  local k="$1" path bytes p o n=0 more=0 files=0 sum=0
  printf '\n## Part review\n'
  printf 'This is part %s of %s of %s#%s at %s. You read only this part'"'"'s files. The other parts hold the files listed below, and other reviewers read them. Judge only this part'"'"'s files. A finding about a file you do not see is outside your verdict. Name a cross-part concern as a NOTE.\n' \
    "$k" "$LPR_N" "$2" "$3" "$4"
  while IFS=$'\t' read -r p o bytes path; do
    [ "$p" = "$k" ] || continue
    files=$((files + 1)); sum=$((sum + bytes))
  done < "$LPR_TSV"
  printf 'This part'"'"'s files (%s files, %s bytes of diff):\n' "$files" "$sum"
  awk -F'\t' -v k="$k" '$1 == k { printf "- %s (%s bytes)\n", $4, $3 }' "$LPR_TSV"
  printf 'The other parts (read by other reviewers, not by you):\n'
  while IFS=$'\t' read -r p o bytes path; do
    [ "$p" = "$k" ] && continue
    n=$((n + 1))
    if [ "$n" -le "$LDP_LIST_MAX" ]; then printf -- '- part %s: %s (%s bytes)\n' "$p" "$path" "$bytes"; else more=$((more + 1)); fi
  done < "$LPR_TSV"
  [ "$more" -gt 0 ] && printf '+%s more files, not listed\n' "$more"
  printf '\n## Diff coverage\n'
  printf 'Part %s of %s: %s files, %s bytes of diff, read whole. The part limit is %s bytes.\n' "$k" "$LPR_N" "$files" "$sum" "$LPR_BYTES"
  awk '/^Digest/ { f = 1 } /^## Diff$/ { exit } f' "$LPR_WT.pparts"
  printf '\n## Diff\n'
  while IFS=$'\t' read -r p o bytes path; do
    [ "$p" = "$k" ] || continue
    git -C "$LPR_WT" diff --no-renames "$5...$4" -- ":(literal)$path" || return 1
  done < "$LPR_TSV"
}

lpr_plan() {
  local wt="$1" base="$2" sha="$3" dmax="$4" repo="$5" pr="$6" rc tot dig rows p o b path k sz f
  LPR_N=0; LPR_PFP=""; LPR_WHY=""; LPR_WT="$wt"; LPR_TSV="$wt.ptsv"
  lpr_knobs "$dmax"
  [ "$LPR_ON" = 1 ] || { LPR_WHY="part review is off (LEAD_REVIEW_PART_REVIEW_ENABLED=${LEAD_REVIEW_PART_REVIEW_ENABLED-})"; return 1; }
  for f in ldp_build lead_fp lr_guard_spent job_ledger_row job_ledger_put lr_verdict; do
    command -v "$f" >/dev/null 2>&1 || { LPR_WHY="part review needs $f, which is not loaded"; return 1; }
  done
  # A subshell: the host's LDP_* summary of the DIFF_MAX read stays as it was.
  rm -f "$LPR_TSV" "$wt.ptail."*
  ( LDP_PARTS_TSV="$LPR_TSV" ldp_build "$wt" "$base" "$sha" "$LPR_BYTES" "$wt.pparts" "$wt.psplit" any; rc=$?
    printf '%s %s\n' "$LDP_TOTAL_FILES" "$LDP_DIGEST_FILES"; exit "$rc" ) > "$wt.pmeta" 2>/dev/null; rc=$?
  case "$rc" in 0|2) ;; *) LPR_WHY="the parts could not be planned (rc $rc)"; return 1 ;; esac
  read -r tot dig < "$wt.pmeta"
  [ -s "$LPR_TSV" ] || { LPR_WHY="the parts could not be planned (no partition)"; return 1; }
  # Refuse a unit over the limit alone, and more parts than LEAD_REVIEW_PART_MAX.
  path=$(awk -F'\t' '$2 == 1 { print $4; exit }' "$LPR_TSV")
  [ -z "$path" ] || { LPR_WHY="$path is over the part limit of $LPR_BYTES bytes alone"; return 1; }
  LPR_N=$(awk -F'\t' '$1 + 0 > n { n = $1 + 0 } END { print n + 0 }' "$LPR_TSV")
  [ "$LPR_N" -le "$LPR_MAX" ] || { LPR_WHY="$LPR_N parts, over LEAD_REVIEW_PART_MAX=$LPR_MAX"; LPR_N=0; return 1; }
  # Coverage, fail closed: every file that is not a digest is in exactly one part.
  git -C "$wt" diff --no-renames -z --numstat "$base...$sha" 2>/dev/null \
    | while IFS= read -r -d '' rec; do rec="${rec#*$'\t'}"; printf '%s\n' "${rec#*$'\t'}"; done > "$wt.pnum"
  rows=$(grep -c . "$LPR_TSV")
  if [ "$(grep -c . "$wt.pnum")" != "$tot" ] || [ "$rows" != "$((tot - dig))" ] \
     || [ "$(cut -f4 "$LPR_TSV" | sort -u | grep -c .)" != "$rows" ] \
     || [ -n "$(cut -f4 "$LPR_TSV" | sort -u | comm -23 - <(sort -u "$wt.pnum"))" ]; then
    LPR_WHY="the parts do not cover the diff once each ($rows parts rows, $tot files, $dig digest)"; LPR_N=0; return 1
  fi
  while IFS=$'\t' read -r p o b path; do
    [ "$(ldp_class "$path")" = digest ] && { LPR_WHY="the part list holds the digest file $path"; LPR_N=0; return 1; }
  done < "$LPR_TSV"
  for ((k = 1; k <= LPR_N; k++)); do
    awk -F'\t' -v k="$k" '$1 == k { f = 1 } END { exit !f }' "$LPR_TSV" || { LPR_WHY="part $k of $LPR_N is empty"; LPR_N=0; return 1; }
    _lpr_tail "$k" "$repo" "$pr" "$sha" "$base" > "$wt.ptail.$k" 2>/dev/null || { LPR_WHY="part $k could not be read"; LPR_N=0; return 1; }
    sz=$(wc -c < "$wt.ptail.$k" | tr -d ' ')
    [ "$sz" -le "$LPR_BYTES" ] || { LPR_WHY="the prompt of part $k is $sz bytes, over the part limit of $LPR_BYTES"; LPR_N=0; return 1; }
  done
  LPR_PFP=$(sha256sum "$LPR_TSV" | cut -c1-8)
  return 0
}

lpr_prompt() { cat "$2" "$LPR_WT.ptail.$1" > "$3"; }

# _lpr_detail <body-file> <request-id> <k> <model> <path> — the ledger and
#   artifact detail, cut to 4000 UTF-16 units on the encoded length (lr_detail).
_lpr_detail() {
  jq -Rsc --arg r "$2" --argjson k "$3" --argjson n "$LPR_N" --arg m "$4" --arg p "$5" --argjson cap 4000 '
    def u16: explode | map(if . > 65535 then 2 else 1 end) | add // 0;
    def obj($b): {request_id: $r, part: $k, of: $n, model: $m, path: $p, body: $b};
    def cut($i): obj(explode[0:$i] | implode) + {truncated: true};
    . as $b
    | if (obj($b) | tojson | u16) <= $cap then obj($b)
      else [0, ($b | explode | length)]
        | until(.[0] >= .[1]; ((.[0] + .[1] + 1) / 2 | floor) as $i
            | if ($b | cut($i) | tojson | u16) <= $cap then [$i, .[1]] else [.[0], $i - 1] end)
        | .[0] as $i | $b | cut($i)
      end' "$1"
}

# _lpr_live <repo> <pr> <sha> <when> — rc 0 when the PR is open at <sha>. Else
#   LPR_RC (superseded or release) and LPR_DETAIL, rc 1.
_lpr_live() {
  local live state
  if ! gh_rest GET "repos/$1/pulls/$2" > "$LPR_WT.lpr.pr" 2>/dev/null \
     || ! live=$(jq -r '.head.sha // empty' "$LPR_WT.lpr.pr" 2>/dev/null) || [ -z "$live" ]; then
    LPR_RC=release; LPR_DETAIL="live head unreadable $4"; return 1
  fi
  state=$(jq -r '.state // empty' "$LPR_WT.lpr.pr" 2>/dev/null)
  if [ -n "$state" ] && [ "$state" != open ]; then LPR_RC=superseded; LPR_DETAIL="pr closed during part review"; return 1; fi
  [ "$live" = "$3" ] || { LPR_RC=superseded; LPR_DETAIL="head moved to ${live:0:12} during part review"; return 1; }
}

# _lpr_call <k> <fp> <out> — one paid call on guard key <fp>. rc = agent-call's.
#   No tools: the part prompt carries its whole files, and a diff must not drive
#   a tool call. A runner that cannot fence tools refuses (rc 78 = release).
_lpr_call() {
  AGENT_CALL_NO_TOOLS=1 AGENT_CALL_GUARD_STAGE=lead-head AGENT_CALL_FP="$2" AGENT_CALL_ROW_NOTE="lead-mode=part $1/$LPR_N" \
  AGENT_CALL_PR="https://github.com/$_LPR_REPO/pull/$_LPR_PR" AGENT_CALL_ROLE=lead.review \
    "$H/bin/agent-call.sh" lead-review "$_LPR_PROJECT" "$_LPR_MODEL" "$_LPR_LEFT" "$3" "@$LPR_WT.lpr.prompt.$1" >/dev/null 2>&1
}

lpr_run() {
  local project="$1" repo="$2" pr="$3" sha="$4" model="$5" common="$6" job="$8" key="$9" rid="${10}"
  local k pk fp fpx fpn row rc st v o pf dir detail gpaid left cut marked=0
  local -a V=()
  LPR_RC=""; LPR_VERDICT=""; LPR_DETAIL=""; LPR_SUM=""; LPR_WT="$7"; LPR_OUT="$7.lpr.out"
  _LPR_PROJECT="$project"; _LPR_REPO="$repo"; _LPR_PR="$pr"; _LPR_MODEL="$model"
  dir="$H/state/lead-reviews/parts"; mkdir -p "$dir" 2>/dev/null
  for ((k = 1; k <= LPR_N; k++)); do
    _lpr_live "$repo" "$pr" "$sha" "before part $k" || return 0
    pk="$repo#$pr@$sha/p${k}of$LPR_N/$LPR_PFP"; o="$LPR_WT.lpr.p$k"
    pf="$dir/${repo//\//_}-$pr-${sha:0:12}-p${k}of$LPR_N.md"
    fpx=$(lead_fp "$repo" "$pr" "$sha" "p${k}of${LPR_N}x$LPR_PFP"); fpn=$(lead_fp "$repo" "$pr" "$sha" "p${k}of${LPR_N}n$LPR_PFP")
    # Dedupe BEFORE spend: a part with a stored verdict is not bought again.
    row=$(job_ledger_row lead_part "$pk" </dev/null); rc=$?; cut=""
    case "$rc" in
      0) st=$(jq -r '.status // ""' <<<"$row" 2>/dev/null)
         case "$st" in MERGE|MERGE-WITH-NOTES|BLOCK)
           if [ -f "$pf" ] && [ "$(lr_verdict "$pf")" = "$st" ]; then cp -f "$pf" "$o"
             V[k]="$st"; _lpr_log "$key: part $k of $LPR_N: $st, stored in the part ledger; no agent call"; continue
           fi
           # The ledger body is cut to the worker's 4000-unit detail cap. A cut
           # (or unreadable) body would drop that part's later findings from the
           # report and the fix round, so it is not reused: fail closed below.
           detail=$(jq -r '.detail // ""' <<<"$row" 2>/dev/null)
           if [ "$(jq -r 'if type == "object" then (.truncated // false) else true end' <<<"$detail" 2>/dev/null)" = false ]; then
             jq -r '.body // ""' <<<"$detail" > "$o" 2>/dev/null
             V[k]="$st"; _lpr_log "$key: part $k of $LPR_N: $st, stored in the part ledger; no agent call"; continue
           fi
           cut=" (its stored answer is cut to the ledger cap and the full local file $pf is missing)"
           _lpr_log "$key: part $k of $LPR_N: $st in the part ledger, but the stored answer is cut and $pf is missing; not reused" ;;
         esac ;;
      2) ;;
      *) LPR_RC=release; LPR_DETAIL="the part ledger is unreadable at part $k"; return 0 ;;
    esac
    if gpaid=$(lr_guard_spent "$project" "$fpx"); then
      LPR_RC=lost; LPR_DETAIL="part $k of $LPR_N is paid ($gpaid on $fpx) with no ${cut:+full }stored answer$cut"
      "$H/bin/lane-alert.sh" --severity warn --id "lead-part-lost-${repo//\//_}-$pr-${sha:0:12}" lead-review \
        "LEAD PART LOST: $repo#$pr@${sha:0:12}: $LPR_DETAIL. No lead verdict on this head. Recover: bin/jobs-client.sh call-guard-reset $project lead-head \"$fpx\" \"<reason>\" (BH-8533)" \
        >/dev/null 2>&1 || _lpr_log "$key: lane-alert for the lost part $k failed"
      return 0
    fi
    left=$(( (DEADLINE - SECONDS) / (LPR_N - k + 1) ))
    [ "$left" -ge "$LPR_LEFT_MIN" ] || { LPR_RC=release; LPR_DETAIL="${left}s left for part $k of $LPR_N, under ${LPR_LEFT_MIN}s"; return 0; }
    _LPR_LEFT="$left"
    lpr_prompt "$k" "$common" "$LPR_WT.lpr.prompt.$k" || { LPR_RC=release; LPR_DETAIL="the prompt of part $k could not be written"; return 0; }
    v=unknown
    for fp in "$fpx" "$fpn"; do
      _lpr_call "$k" "$fp" "$o"; rc=$?
      if [ "$rc" -ge 74 ] && [ "$rc" -le 79 ]; then LPR_RC=release; LPR_DETAIL="agent-call rc $rc on part $k: nothing billed"; return 0; fi
      lr_rate_limited "$rc" "$o" && { LPR_RC=ratelimit; LPR_DETAIL="$rc"; return 0; }
      # The per-PR tripwire counts one review a head, not one a part.
      [ "$marked" = 0 ] && [ "${MODE:-}" = tick ] && command -v lw_pr_day_mark >/dev/null 2>&1 && lw_pr_day_mark "$repo" "$pr"
      marked=1
      lr_pick_review "$o" "$key" && v=$(lr_verdict "$o")
      [ "$v" = unknown ] || break
    done
    if [ "$v" = unknown ]; then LPR_RC=empty; LPR_DETAIL="part $k of $LPR_N had no readable verdict after one retry"; return 0; fi
    # Persist before the next part: the local file, the ledger row, the artifact.
    cp -f "$o" "$pf.tmp.$$" && mv -f "$pf.tmp.$$" "$pf" || _lpr_log "$key: could not write $pf"
    detail=$(_lpr_detail "$o" "$rid" "$k" "$model" "$pf")
    job_ledger_put lead_part "$pk" "$v" "$detail" </dev/null || _lpr_log "$key: part $k ledger put failed; the local file $pf holds it"
    job_artifact_put lead_review_part "$pf" "$detail" "$job" </dev/null || _lpr_log "$key: part $k artifact put failed"
    V[k]="$v"; _lpr_log "$key: part $k of $LPR_N: $v"
  done
  _lpr_live "$repo" "$pr" "$sha" "after part $LPR_N" || return 0
  for ((k = 1; k <= LPR_N; k++)); do LPR_SUM="${LPR_SUM:+$LPR_SUM, }$k ${V[k]}"; done
  lpr_aggregate "$LPR_OUT" "${V[@]}" || { LPR_RC=release; LPR_DETAIL="the aggregate could not be written"; return 0; }
  LPR_RC=ok
}

# lpr_aggregate <out> <verdict of part 1> ... <verdict of part N> — BLOCK when
#   any part is BLOCK, else MERGE-WITH-NOTES when any part is, else MERGE. Each
#   part's answer keeps its findings; its own VERDICT lines read `Part verdict:`
#   and a bare `---` rule reads `----`, so only the last line is a verdict.
lpr_aggregate() {
  local out="$1" agg=MERGE k=0 v
  shift
  [ "$#" = "$LPR_N" ] || return 1
  for v in "$@"; do
    case "$v" in
      BLOCK) agg=BLOCK ;;
      MERGE-WITH-NOTES) [ "$agg" = BLOCK ] || agg=MERGE-WITH-NOTES ;;
      MERGE) ;;
      *) return 1 ;;
    esac
  done
  {
    printf 'Part review: %s parts, one reviewer each. The verdict is BLOCK when any part is BLOCK, else MERGE-WITH-NOTES when any part is, else MERGE.\n\n' "$LPR_N"
    for v in "$@"; do
      k=$((k + 1))
      printf '## Part %s of %s: %s\nFiles: %s\n\n' "$k" "$LPR_N" "$v" "$(awk -F'\t' -v k="$k" '$1 == k { print $4 }' "$LPR_TSV" | paste -sd, - | sed 's/,/, /g')"
      tr -d '\r' < "$LPR_WT.lpr.p$k" | sed -E 's/^([[:space:]#>*]*)VERDICT([*]*):/\1Part verdict\2:/I; s/^---$/----/'
      printf '\n'
    done
    printf 'VERDICT: %s\n' "$agg"
  } > "$out"
  LPR_VERDICT="$agg"
}
