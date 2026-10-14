#!/bin/bash
# bin/plan-sibling.sh — SEQUENCE ROLLOUT SIBLINGS ON ANY SHARED FILE (BH-4988 r2,
# BH-4975.3; the operator 2026-10-07: "Sequence any two siblings whose planned file sets
# intersect, not only on hotspot files ... Siblings with disjoint files still
# build in parallel." and "Log each sequencing decision on the child ticket.")
#
# WHY, ON TOP OF bin/plan-overlap.sh. plan-overlap compares a fresh plan with
# every build IN FLIGHT: job_claims rows (the worker lists only status
# 'running'), claim files (removed when a build exits) and live build dirs (a
# RESULT means finished). A sibling that finished building but whose PR is not
# merged is in none of them, so the next sibling plans, builds the same file and
# the two PRs conflict at merge (BH-3921.1 vs .2 on bin/lib/triage-state.sh).
# This reads that sibling's file set from its OPEN PR, which is the set it
# actually wrote, and answers in plan-overlap's own line, so bin/lib/rb/gates.sh
# takes the same defer path and bin/plan-after.sh holds the ticket for free
# until that PR merges or closes.
#
# usage:
#   plan-sibling.sh check <project> <build-dir>
#     Only for a child ticket (a line-anchored `Part of #<P>` in
#     ticket-meta.json .body) on a GitHub-Issues board (fleet.conf board prefix
#     `-`). Siblings are the open issues with the same `Part of #<P>`; their open
#     PRs are the ones whose head is ticket/<prefix>-<n>[-rN] or agent/<PREFIX>-<n>.
#     The PR this build is stacked on (PLAN_SIBLING_STACK_ON) is skipped.
#     exit 0  build: disjoint, not a child, in-app board, kill switch, or a read
#             failed (fail-open, logged `unjudged=`, never as "no siblings").
#     exit 1  overlap. stdout is exactly `OVERLAP_DEFER <KEY> vs <SIBKEY> files=[..]`.
#   plan-sibling.sh note <project> <KEY> "<OVERLAP_DEFER line>" <build-dir>
#     Posts ONE comment on the child issue per (KEY, OTHER) pair saying why it is
#     held. Deduped through bin/lib/comment-mark.sh, key `sequenced <project>
#     <KEY>:<OTHER>`; the mark is written only after the post answered rc 0. A
#     failed post is logged and retried at the next defer; it never fails a build.
#     The PR number in the copy is read from this build's `PLAN_SIBLING ...
#     choice=after after=<OTHER> pr=#<n>` pipeline.log line, when check wrote one.
#   exit 2  usage.
#
# THE OVERLAP RULE is plan-overlap.sh's `overlap` (file == file, or dir-prefix,
# with the same-list bare-dir prune) and the FRAGMENT RULE is plan-overlap.sh's
# `fragment_safe`, both copied here rather than extracted while open PR #5310
# rewrites that file. Keep the two in step.
#
# Every choice is one PLAN_SIBLING line on stderr (the build's pipeline.log) and
# in logs/plan-hotspot.log.
#
# KILL FLAG: plan-overlap's own (OVERLAP_SCHED=0|off|false|no, env or
# env/global.env; or lane_switch plan-overlap-off), then PLAN_SIBLING_SEQ=0 for
# check and PLAN_SIBLING_COMMENT=0 for note (catalog/lanes.d/_lib.plan-sibling.json).
set -uo pipefail
MODE="${1:-}"
HARNESS="${HARNESS:-/root/harness}"
HERE="$(cd "$(dirname "$0")" && pwd)"
case "$MODE" in
  check) [ $# -eq 3 ] || MODE="" ;;
  note)  [ $# -eq 5 ] || MODE="" ;;
  *)     MODE="" ;;
esac
if [ -z "$MODE" ]; then
  echo "usage: plan-sibling.sh check <project> <build-dir> | note <project> <KEY> \"<OVERLAP_DEFER line>\" <build-dir>" >&2
  exit 2
fi
PROJECT="$2"
# shellcheck source=bin/lib/env-path.sh
. "$HERE/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-$HARNESS}/env"; }
GENV="$(harness_env_dir "$HARNESS")/global.env"

genv() { # genv <NAME> — the env value, else the last env/global.env assignment
  local v="${!1:-}"
  if [ -z "$v" ] && [ -r "$GENV" ]; then
    v=$(sed -n "s/^[[:space:]]*\\(export[[:space:]]\\{1,\\}\\)\\{0,1\\}$1=//p" "$GENV" | tr -d "\"' \t" | tail -1)
  fi
  printf '%s' "$v"
}
off() { case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in 0|off|false|no) return 0 ;; esac; return 1; }
num() { case "$1" in ''|*[!0-9]*) printf '%s' "$2" ;; *) printf '%s' "$1" ;; esac; }

# Kill switches before any read.
off "$(genv OVERLAP_SCHED)" && exit 0
# shellcheck source=bin/lib/lane-switch.sh
. "$HERE/lib/lane-switch.sh" 2>/dev/null || true
command -v lane_switch >/dev/null 2>&1 || lane_switch() { [ -f "$HARNESS/flags/$1" ]; }
lane_switch plan-overlap-off && exit 0
command -v lib_env_apply >/dev/null 2>&1 && lib_env_apply plan-sibling "$PROJECT" >/dev/null 2>&1

valid_key() { [[ "${1:-}" =~ ^[A-Za-z0-9._-]{1,64}$ ]] && [ "$1" != . ] && [ "$1" != .. ]; }
psib_log() { # psib_log <line> — stderr and logs/plan-hotspot.log
  echo "$1" >&2
  mkdir -p "$HARNESS/logs" 2>/dev/null && printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" >> "$HARNESS/logs/plan-hotspot.log" 2>/dev/null
  return 0
}
# parent_of — the first line-anchored `Part of #<n>` in the JSON string on stdin
# (bin/unblocked-children.sh's part_re), or nothing.
# jq's ^/$ anchor the whole string, so the body is matched line by line.
PART_RE='^[\s>*_\-]*Part of #(?<n>[0-9]+)\s*$'
PART_JQ='def part_of: [(. // "") | split("\n")[] | capture($re; "i").n][0] // "";'
parent_of() { jq -r --arg re "$PART_RE" "$PART_JQ"' part_of' 2>/dev/null; }

valid_key "$PROJECT" || { echo "plan-sibling: refusing project '$PROJECT'" >&2; [ "$MODE" = note ] && exit 1; exit 0; }
if [ "$MODE" = check ]; then BUILD="$3"; else BUILD="$5"; fi
[ -d "$BUILD" ] || exit 0
PARENT=$(jq '.body // ""' "$BUILD/ticket-meta.json" 2>/dev/null | parent_of)

# =============================================================================
# note
# =============================================================================
if [ "$MODE" = note ]; then
  KEY="$3"; LINE="$4"
  OTHER=$(printf '%s\n' "$LINE" | awk 'NR==1 && $1=="OVERLAP_DEFER" && $3=="vs" {print $4}')
  if ! valid_key "$KEY" || ! valid_key "$OTHER"; then
    echo "plan-sibling: refusing key/other '$KEY'/'$OTHER'" >&2; exit 1
  fi
  NUM="${KEY##*-}"
  case "$NUM" in ''|*[!0-9]*) echo "plan-sibling: no issue number in '$KEY'" >&2; exit 1 ;; esac
  [ -n "$PARENT" ] || exit 0
  [ "$("$HARNESS/bin/fleet-conf.sh" "$PROJECT" board_prefix 2>/dev/null)" = - ] || exit 0
  if off "$(genv PLAN_SIBLING_COMMENT)"; then psib_log "PLAN_SIBLING $KEY comment=off after=$OTHER"; exit 0; fi
  SLUG=$("$HARNESS/bin/fleet-conf.sh" "$PROJECT" repo 2>/dev/null)
  [ -n "$SLUG" ] || { psib_log "PLAN_SIBLING $KEY comment=failed after=$OTHER reason=no-repo"; exit 0; }
  # shellcheck source=/dev/null
  [ -r "$HARNESS/bin/jobs-client.sh" ] && . "$HARNESS/bin/jobs-client.sh" >/dev/null 2>&1
  # shellcheck source=bin/lib/comment-mark.sh
  . "$HERE/lib/comment-mark.sh" || exit 0
  MKEY="sequenced $PROJECT $KEY:$OTHER"
  MFILE="$HARNESS/state/comment-marks/sequenced/$PROJECT/$KEY.$OTHER"
  if cm_has "$MKEY" - "$MFILE"; then psib_log "PLAN_SIBLING $KEY comment=already after=$OTHER"; exit 0; fi
  # The files, deduped, at most 3, from the pairs `files=[p,q,p,q,...]`.
  FL=$(printf '%s' "$LINE" | sed -n 's/.*files=\[\([^]]*\)\].*/\1/p' | tr ',' '\n' | awk 'NF && !s[$0]++' | head -3)
  FT=""; i=0; n=$(printf '%s\n' "$FL" | awk 'NF' | wc -l)
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    i=$((i+1))
    if [ "$i" = 1 ]; then FT="\`$f\`"; elif [ "$i" = "$n" ]; then FT="$FT and \`$f\`"; else FT="$FT, \`$f\`"; fi
  done <<< "$FL"
  [ -n "$FT" ] || FT="the same files"
  PRN=$(grep -o "PLAN_SIBLING $KEY choice=after after=$OTHER pr=#[0-9]*" "$BUILD/pipeline.log" 2>/dev/null | tail -1 | sed 's/.*pr=#//')
  BODY=$(mktemp "${TMPDIR:-/tmp}/plan-sibling.XXXXXX") || exit 0
  trap 'rm -f "$BODY"' EXIT
  if [ -n "$PRN" ]; then
    printf "Holding this one until %s (#%s) merges. Both plan to edit %s, and building them side by side would conflict at merge. It re-checks before every planning pass and starts on its own once %s's PR is merged or closed. Nothing for you to do.\n\n<!-- plan-sibling:%s:%s -->\n" \
      "$OTHER" "$PRN" "$FT" "$OTHER" "$KEY" "$OTHER" > "$BODY"
  else
    printf "Holding this one until %s merges. Both plan to edit %s, and building them side by side would conflict at merge. It re-checks before every planning pass and starts on its own once %s is done building and has no open PR. Nothing for you to do.\n\n<!-- plan-sibling:%s:%s -->\n" \
      "$OTHER" "$FT" "$OTHER" "$KEY" "$OTHER" > "$BODY"
  fi
  # shellcheck source=bin/lib/gh-rest-list.sh
  . "$HERE/lib/gh-rest-list.sh" 2>/dev/null
  RC=0
  if command -v gh_rest_comment >/dev/null 2>&1; then gh_rest_comment "$SLUG" "$NUM" "$BODY" || RC=$?; else RC=127; fi
  if [ "$RC" != 0 ]; then psib_log "PLAN_SIBLING $KEY comment=failed rc=$RC after=$OTHER"; exit 0; fi
  # BH-5799: the build's own note, so the plan thread gate does not refuse this
  # build's plan on it when the dir is resumed.
  # shellcheck source=bin/lib/plan-thread.sh
  . "$HERE/lib/plan-thread.sh" 2>/dev/null && ptg_own_post "$BUILD" "$BODY"
  cm_put "$MKEY" - "$MFILE" || psib_log "PLAN_SIBLING $KEY comment=posted-unmarked after=$OTHER"
  psib_log "PLAN_SIBLING $KEY comment=posted after=$OTHER"
  exit 0
fi

# =============================================================================
# check
# =============================================================================
off "$(genv PLAN_SIBLING_SEQ)" && exit 0
CFILES="$BUILD/planned-files.txt"
# BH-5965: a plan that declares its files is judged on that list (bin/touch-files.sh).
if [ "$(cat "$BUILD/touch-source" 2>/dev/null)" = declared ] && [ -s "$BUILD/touch-files.txt" ]; then
  CFILES="$BUILD/touch-files.txt"
fi
[ -s "$CFILES" ] || exit 0
KEY=$(jq -r '.key // .ticket_key // empty' "$BUILD/ticket-meta.json" 2>/dev/null)
[ -n "$KEY" ] || KEY=$(basename "$BUILD" | sed -E "s/^${PROJECT}-//; s/-[0-9]{8,}$//")
[ -n "$PARENT" ] || exit 0
if [ "$("$HARNESS/bin/fleet-conf.sh" "$PROJECT" board_prefix 2>/dev/null)" != - ]; then
  psib_log "PLAN_SIBLING $KEY choice=build unjudged=in-app-board"; exit 0
fi
SLUG=$("$HARNESS/bin/fleet-conf.sh" "$PROJECT" repo 2>/dev/null)
[ -n "$SLUG" ] || { psib_log "PLAN_SIBLING $KEY choice=build unjudged=no-repo"; exit 0; }
PREFIX="${KEY%-*}"; MYNUM="${KEY##*-}"
if [ "$PREFIX" = "$KEY" ] || ! valid_key "$PREFIX"; then
  psib_log "PLAN_SIBLING $KEY choice=build unjudged=key-shape"; exit 0
fi
PU=$(printf '%s' "$PREFIX" | tr '[:lower:]' '[:upper:]'); PL=$(printf '%s' "$PREFIX" | tr '[:upper:]' '[:lower:]')
MAXI=$(num "$(genv PLAN_SIBLING_MAX_ISSUES)" 500); [ "$MAXI" -ge 100 ] || MAXI=100
MAXP=$(num "$(genv PLAN_SIBLING_MAX_PRS)" 8); [ "$MAXP" -ge 1 ] || MAXP=1

# shellcheck source=bin/lib/gh-rest-list.sh
. "$HERE/lib/gh-rest-list.sh" 2>/dev/null
TMPD=$(mktemp -d "${TMPDIR:-/tmp}/plan-sibling.XXXXXX") || exit 0
trap 'rm -rf "$TMPD"' EXIT
INC=""
RC=0; gh_rest_issue_list "$SLUG" open "" "$MAXI" > "$TMPD/issues.json" || RC=$?
[ "$RC" = 0 ] || { psib_log "PLAN_SIBLING $KEY choice=build unjudged=issues rc=$RC"; exit 0; }
NI=$(jq 'if type=="array" then length else -1 end' "$TMPD/issues.json" 2>/dev/null)
case "$NI" in ''|-1) psib_log "PLAN_SIBLING $KEY choice=build unjudged=issues rc=shape"; exit 0 ;; esac
[ "$NI" -ge "$MAXI" ] && INC=" incomplete=1"
jq -r --arg re "$PART_RE" --arg p "$PARENT" --arg me "$MYNUM" "$PART_JQ"'
  .[] | select(.pull_request == null)
  | select((.body | part_of) == $p)
  | select((.number|tostring) != $me) | .number' "$TMPD/issues.json" 2>/dev/null | sort -n > "$TMPD/sibs"
NS=$(awk 'NF' "$TMPD/sibs" | wc -l | tr -d ' ')
[ "$NS" -gt 0 ] || { psib_log "PLAN_SIBLING $KEY choice=build siblings=0$INC"; exit 0; }

RC=0; gh_rest_pr_list_all "$SLUG" open 300 > "$TMPD/pulls.json" || RC=$?
[ "$RC" = 0 ] || { psib_log "PLAN_SIBLING $KEY choice=build unjudged=pulls rc=$RC siblings=$NS"; exit 0; }
case "$(jq 'if type=="array" then length else -1 end' "$TMPD/pulls.json" 2>/dev/null)" in
  ''|-1) psib_log "PLAN_SIBLING $KEY choice=build unjudged=pulls rc=shape siblings=$NS"; exit 0 ;;
esac
# <sibling n> TAB <pr number>, for each open PR on a sibling's branch.
jq -r --arg pl "$PL" --arg pu "$PU" --arg stack "${PLAN_SIBLING_STACK_ON:-}" '
  .[]? | (.head.ref // "") as $r | select($r != "" and $r != $stack)
  | (if ($r|startswith("ticket/"+$pl+"-")) then ($r|ltrimstr("ticket/"+$pl+"-"))
     elif ($r|startswith("agent/"+$pu+"-")) then ($r|ltrimstr("agent/"+$pu+"-")) else "" end) as $t
  | select(($r|startswith("agent/") and ($t|test("^[0-9]+$"))) or ($r|startswith("ticket/") and ($t|test("^[0-9]+(-r[0-9]+)?$"))))
  | "\($t|split("-")[0])\t\(.number)"' "$TMPD/pulls.json" 2>/dev/null \
  | awk -F'\t' 'NR==FNR{s[$1]=1;next} s[$1]' "$TMPD/sibs" - | sort -n -k1,1 -k2,2 > "$TMPD/prs"
NP=$(awk 'NF' "$TMPD/prs" | wc -l | tr -d ' ')

# --- the overlap rule (plan-overlap.sh:overlap) ---------------------------------
overlap() {
  awk 'NR==FNR{a[++na]=$0;next}
    {b[++nb]=$0}
    END{
      for(i=1;i<=na;i++) for(j=1;j<=na;j++) if(index(a[j],a[i]"/")==1){da[i]=1;break}
      for(i=1;i<=nb;i++) for(j=1;j<=nb;j++) if(index(b[j],b[i]"/")==1){db[i]=1;break}
      for(i=1;i<=nb;i++){
        if(db[i])continue
        for(j=1;j<=na;j++){
          if(da[j])continue
          p=a[j]; q=b[i]
          if(q==p || index(q,p"/")==1 || index(p,q"/")==1) print p" ~ "q
        }
      }
    }' "$1" "$2" 2>/dev/null
}
pairs_csv() { printf '%s\n' "$1" | sed 's/ ~ /,/' | tr '\n' ',' | sed 's/,*$//'; }
# --- the fragment rule (plan-overlap.sh:fragment_safe) ----------------------------
REPO_DIR="${PLAN_OVERLAP_REPO:-${REPOS_ROOT:-/root/repos}/$PROJECT}"
FRAG_INIT=0; FRAG_DIRS=""; GEN_PATHS=""
frag_init() {
  local v d
  [ "$FRAG_INIT" = 1 ] && return 0
  FRAG_INIT=1
  command -v lib_env_apply >/dev/null 2>&1 && lib_env_apply plan-hotspot "$PROJECT" >/dev/null 2>&1
  v=$(genv PLAN_OVERLAP_FRAGMENT_DIRS)
  [ -n "$v" ] || v="catalog/lanes.d cron/lanes docs/verification-map/entries worker/jobs/schema.d"
  for d in $v; do d="${d%/}"; [ -n "$d" ] && FRAG_DIRS="$FRAG_DIRS $d"; done
  # shellcheck source=bin/lib/generated-table.sh
  [ -r "$HERE/lib/generated-table.sh" ] && . "$HERE/lib/generated-table.sh" 2>/dev/null
  if command -v gen_table_paths >/dev/null 2>&1 && [ -d "$REPO_DIR" ]; then
    GEN_PATHS=$(gen_table_paths "$REPO_DIR" HEAD 2>/dev/null) || GEN_PATHS=""
  fi
  return 0
}
is_frag_dir() { local d; for d in $FRAG_DIRS; do [ "$1" = "$d" ] && return 0; done; return 1; }
fragment_safe() {
  local p="${1%% ~ *}" q="${1#* ~ }" g
  frag_init
  if [ "$p" = "$q" ]; then
    is_frag_dir "$p" && return 0
    command -v gen_path_matches >/dev/null 2>&1 || return 1
    while IFS= read -r g; do
      [ -n "$g" ] && gen_path_matches "$p" "$g" && return 0
    done <<< "$GEN_PATHS"
    return 1
  fi
  if [ "${#p}" -lt "${#q}" ]; then is_frag_dir "$p"; else is_frag_dir "$q"; fi
}

UNJ=""; READ=0
while IFS=$'\t' read -r SN PRN; do
  [ -n "$PRN" ] || continue
  if [ "$READ" -ge "$MAXP" ]; then INC=" incomplete=1"; break; fi
  READ=$((READ+1))
  RC=0; gh_rest GET "repos/$SLUG/pulls/$PRN/files" -F per_page=100 > "$TMPD/f.json" || RC=$?
  NF=$(jq 'if type=="array" then length else -1 end' "$TMPD/f.json" 2>/dev/null)
  if [ "$RC" != 0 ] || [ -z "$NF" ] || [ "$NF" = -1 ]; then
    UNJ="$UNJ${UNJ:+,}files:#$PRN"; psib_log "PLAN_SIBLING $KEY unjudged=files:#$PRN rc=$RC"; continue
  fi
  [ "$NF" -ge 100 ] && INC=" incomplete=1"
  jq -r '.[].filename // empty' "$TMPD/f.json" > "$TMPD/theirs" 2>/dev/null
  HITS=$(overlap "$CFILES" "$TMPD/theirs")
  [ -n "$HITS" ] || continue
  REAL=""
  while IFS= read -r pr; do
    [ -n "$pr" ] || continue
    fragment_safe "$pr" || REAL="$REAL$pr"$'\n'
  done <<< "$HITS"
  SIBKEY="$PU-$SN"
  if [ -z "$REAL" ]; then
    psib_log "PLAN_SIBLING $KEY choice=build vs $SIBKEY pr=#$PRN fragment-only files=[$(pairs_csv "$(head -3 <<<"$HITS")")]"
    continue
  fi
  CSV=$(pairs_csv "$(head -3 <<<"$REAL")")
  psib_log "PLAN_SIBLING $KEY choice=after after=$SIBKEY pr=#$PRN files=[$CSV]$INC"
  printf 'OVERLAP_DEFER %s vs %s files=[%s]\n' "$KEY" "$SIBKEY" "$CSV"
  exit 1
done < "$TMPD/prs"

if [ -n "$UNJ" ]; then
  psib_log "PLAN_SIBLING $KEY choice=build siblings=$NS prs=$NP unjudged=$UNJ$INC"
else
  psib_log "PLAN_SIBLING $KEY choice=build siblings=$NS prs=$NP disjoint$INC"
fi
exit 0
