# shellcheck shell=bash
# bin/lib/execute-checkpoint-brief.sh — BH-9123 (slice C1 of BH-9064), the execute checkpoint and its
# resume. Sourced by bin/lib/rb/execute.sh and by bin/agent-call.sh's context
# meter (right before a context kill). Functions only: sourcing it does nothing.
#
# ── WHY ──────────────────────────────────────────────────────────────────────
# An execute session that times out (rc 124), is killed (rc 143) or hits its
# context kill used to end the build. The next build of the key started a fresh
# execute from the plan and paid for the same work again. The work is not lost:
# bin/lane-checkpoint.sh pushes it as wip commits. This lib writes a short brief
# of that work, so the next session continues from the last commit.
#
# ── FUNCTIONS ────────────────────────────────────────────────────────────────
#   ecb_write <build> [branch] [base]
#       Writes <build>/checkpoint-brief.md: the last commit, the diff stat
#       against <base>, the plan's "## Acceptance tests" items, and the items
#       that no commit message and no changed file name yet. branch defaults
#       to the current branch. base defaults to the sha in <build>/collision-
#       base, else origin/main. Local git only: no network. Fast.
#   ecb_session_id <build>      the session id of the last execute attempt
#       (<build>/execute-run.txt.session, field 1), or nothing.
#   ecb_resume_sid <build>      the same id, but only when its transcript file
#       is on this box (A6: the CLI fails on a session it cannot find).
#   ecb_checkpoint_text <build> [branch]   "<branch>@<sha12> session=<sid|->"
#   ecb_record <project> <fp> <checkpoint-text>
#       A checkpoint-only finish on the ledger row (project, execute, fp).
#   ecb_park <project> <fp> [checkpoint-text]
#       Settles the ledger row (project, execute, fp) as parked.
#   ecb_get_checkpoint <project> <fp>
#       Prints the checkpoint of the ledger row. rc 0 only when there is one.
#   ecb_render_resume <outvar> <build>
#       Renders prompts/stages/execute-resume.md with the brief in it.
#   ecb_start_prompt <outvar>
#       The first execute call of a NEW build: when the ledger row of
#       (PROJECT, execute, BUILD_CALL_FP) carries a checkpoint, writes the brief
#       and puts the resume prompt in <outvar>. rc 1 (outvar untouched) when
#       there is no checkpoint, no ledger or no template.
# The ledger calls are FAIL-OPEN: no JOBS_URL, no client, a 404, a timeout or a
# 5xx returns non-zero with no output. They never stop a build.
#
# ── KNOBS (env; each read keeps its code default) ────────────────────────────
#   AGENT_LEDGER                  1 | 0, the ledger switch (also the switch
#                                 agent-ledger-off, read with lane_switch when
#                                 it is defined). Same knob and switch as
#                                 bin/lib/agent-call-ledger.sh.
#   AGENT_LEDGER_TIMEOUT_S        the worker timeout of one request (5)
#   EXECUTE_BRIEF_STAT_LINES      diff stat lines in the brief (80)
#   EXECUTE_BRIEF_ITEMS_MAX       acceptance items read from the plan (60)
# The root is ${HARNESS:-${H:-}} (D43). With none, the ledger calls refuse.

_ECB_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"

_ecb_root() { printf '%s' "${HARNESS:-${H:-}}"; }
_ecb_int() { case "${1:-}" in ''|*[!0-9]*) printf '%s' "$2" ;; *) printf '%s' "$((10#$1))" ;; esac; }

# _ecb_base <build> — the diff base: the collision-base sha, else origin/main.
_ecb_base() {
  local b=""
  [ -s "${1:-}/collision-base" ] && read -r b < "$1/collision-base"
  case "$b" in ''|*[!0-9a-f]*) b=origin/main ;; esac
  printf '%s' "$b"
}

# _ecb_items <plan.md> — the top-level items of "## Acceptance tests", one per line.
_ecb_items() {
  local max
  max=$(_ecb_int "${EXECUTE_BRIEF_ITEMS_MAX:-}" 60)
  [ -r "${1:-}" ] || return 0
  awk -v max="$max" '
    /^## / { if (f) exit; if ($0 ~ /^## Acceptance tests[[:space:]]*$/) f = 1; next }
    f && /^(- |\* |[0-9]+\. )/ { if (n++ >= max) exit; sub(/^(- |\* |[0-9]+\. )/, ""); print }
  ' "$1"
}

ecb_session_id() {
  local sid="" rest=""
  [ -s "${1:-}/execute-run.txt.session" ] && IFS=$'\t' read -r sid rest < "$1/execute-run.txt.session" 2>/dev/null
  case "$sid" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  printf '%s' "$sid"
}

ecb_resume_sid() {
  local sid="" cfg="" d j
  [ -s "${1:-}/execute-run.txt.session" ] && IFS=$'\t' read -r sid cfg < "$1/execute-run.txt.session" 2>/dev/null
  case "$sid" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  case "$cfg" in /*) ;; *) cfg="" ;; esac
  # The same search as bin/lib/execute-empty.sh ee_transcript: the account's
  # config dir first, then the default projects dir.
  for d in ${cfg:+"$cfg/projects"} "${CLAUDE_PROJECTS_DIR:-${HOME:-/nonexistent}/.claude/projects}"; do
    j=$(find "$d" -maxdepth 2 -name "$sid.jsonl" -print -quit 2>/dev/null)
    [ -n "$j" ] && [ -s "$j" ] && { printf '%s' "$sid"; return 0; }
  done
  return 1
}

ecb_checkpoint_text() {
  local br="${2:-}" sha sid
  [ -n "$br" ] || br=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
  sha=$(git rev-parse --short=12 HEAD 2>/dev/null) || sha=""
  sid=$(ecb_session_id "${1:-}") || sid=""
  printf '%s@%s session=%s' "${br:--}" "${sha:--}" "${sid:--}"
}

ecb_write() {
  local build="${1:-}" br="${2:-}" base="${3:-}" last stat changed msgs item paths p hit sid statn
  [ -n "$build" ] && [ -d "$build" ] || return 1
  [ -n "$br" ] || br=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
  [ -n "$base" ] || base=$(_ecb_base "$build")
  statn=$(_ecb_int "${EXECUTE_BRIEF_STAT_LINES:-}" 80)
  last=$(git log -1 --format='%h %s' 2>/dev/null) || last=""
  stat=$(git diff --stat "$base"...HEAD 2>/dev/null | tail -n "$statn")
  changed=$(git diff --name-only "$base"...HEAD 2>/dev/null)
  msgs=$(git log --format=%B "$base"..HEAD 2>/dev/null)
  sid=$(ecb_session_id "$build") || sid=""
  local done_l="" open_l="" n=0
  while IFS= read -r item; do
    [ -n "$item" ] || continue
    n=$((n + 1))
    # Best effort: an item is done when a test path it names is a changed file,
    # or its file name is in a commit message.
    paths=$(grep -oE '[A-Za-z0-9._/-]*(tests?/|\.test\.|-test\.|_test\.)[A-Za-z0-9._/-]*' <<<"$item" | sed 's/[.,;:]*$//' | sort -u)
    hit=""
    for p in $paths; do
      { grep -qxF "$p" <<<"$changed" || grep -qF "${p##*/}" <<<"$msgs"; } && { hit=1; break; }
    done
    if [ -n "$hit" ]; then done_l+="- $item"$'\n'
    elif [ -z "$paths" ]; then open_l+="- $item (it names no test file: check it by hand)"$'\n'
    else open_l+="- $item"$'\n'; fi
  done < <(_ecb_items "$build/plan.md")
  {
    echo "# Execute checkpoint brief"
    echo
    echo "Branch: ${br:--}"
    echo "Base: $base"
    echo "Last commit: ${last:-none}"
    echo "Session: ${sid:--}"
    echo
    echo "## Diff so far (git diff --stat $base...HEAD)"
    echo
    if [ -n "$stat" ]; then printf '%s\n' "$stat"; else echo "(no diff)"; fi
    echo
    echo "## Acceptance items done (a changed file or a commit message names their test)"
    echo
    if [ -n "$done_l" ]; then printf '%s' "$done_l"; else echo "(none yet)"; fi
    echo
    echo "## Acceptance items still open"
    echo
    if [ -n "$open_l" ]; then printf '%s' "$open_l"
    elif [ "$n" = 0 ]; then echo "(the plan has no \"## Acceptance tests\" items)"
    else echo "(none: run the VALIDATE commands and finish)"; fi
  } > "$build/checkpoint-brief.md.tmp.$$" 2>/dev/null \
    && mv -f "$build/checkpoint-brief.md.tmp.$$" "$build/checkpoint-brief.md" 2>/dev/null \
    || { rm -f "$build/checkpoint-brief.md.tmp.$$" 2>/dev/null; return 1; }
}

# _ecb_ledger — rc 0 when the ledger is on and its client is loaded.
_ecb_ledger() {
  local r
  r=$(_ecb_root); [ -n "$r" ] || return 1
  [ "${AGENT_LEDGER:-1}" = 1 ] || return 1
  # The switch is read the way bin/lib/agent-call-ledger.sh reads it.
  command -v lane_switch >/dev/null 2>&1 && HARNESS="$r" lane_switch agent-ledger-off file && return 1
  if ! command -v _jobs_req >/dev/null 2>&1; then
    # shellcheck source=bin/jobs-client.sh
    [ -r "$r/bin/jobs-client.sh" ] && . "$r/bin/jobs-client.sh" >/dev/null 2>&1
  fi
  [ -n "${JOBS_URL:-}" ] || return 1
  if ! command -v acl_req_finish >/dev/null 2>&1; then
    # shellcheck source=bin/lib/jobs/agent-call-ledger.sh
    if [ -r "$r/bin/lib/jobs/agent-call-ledger.sh" ]; then . "$r/bin/lib/jobs/agent-call-ledger.sh" 2>/dev/null
    elif [ -r "$_ECB_LIB_DIR/jobs/agent-call-ledger.sh" ]; then . "$_ECB_LIB_DIR/jobs/agent-call-ledger.sh" 2>/dev/null; fi
  fi
  command -v acl_req_finish >/dev/null 2>&1 && command -v _jobs_req >/dev/null 2>&1
}

# _ecb_finish <json> — one finish request; no output, rc of the request.
_ecb_finish() {
  local f rc
  _ecb_ledger || return 1
  f=$(mktemp "${TMPDIR:-/tmp}/ecb-finish.XXXXXX") || return 1
  printf '%s' "$1" > "$f"
  JOBS_TIMEOUT="$(_ecb_int "${AGENT_LEDGER_TIMEOUT_S:-}" 5)" acl_req_finish "$f" >/dev/null 2>&1; rc=$?
  rm -f "$f"
  return "$rc"
}

ecb_record() {
  local body
  [ -n "${1:-}" ] && [ -n "${2:-}" ] && [ -n "${3:-}" ] || return 1
  body=$(jq -nc --arg p "$1" --arg f "$2" --arg c "$3" '{project:$p,stage:"execute",fp:$f,checkpoint:$c}' 2>/dev/null) || return 1
  _ecb_finish "$body"
}

ecb_park() {
  local body
  [ -n "${1:-}" ] && [ -n "${2:-}" ] || return 1
  body=$(jq -nc --arg p "$1" --arg f "$2" --arg c "${3:-}" \
    '{project:$p,stage:"execute",fp:$f,status:"parked"} + (if $c == "" then {} else {checkpoint:$c} end)' 2>/dev/null) || return 1
  _ecb_finish "$body"
}

ecb_get_checkpoint() {
  local resp ck
  [ -n "${1:-}" ] && [ -n "${2:-}" ] || return 1
  _ecb_ledger || return 1
  command -v acl_req_get >/dev/null 2>&1 || return 1
  resp=$(JOBS_TIMEOUT="$(_ecb_int "${AGENT_LEDGER_TIMEOUT_S:-}" 5)" acl_req_get "$1" execute "$2" 2>/dev/null) || return 1
  ck=$(printf '%s' "$resp" | jq -r '(.row // .) | .checkpoint // empty' 2>/dev/null)
  [ -n "$ck" ] || return 1
  printf '%s' "$ck"
}

ecb_render_resume() {
  local _ecb_ov="${1:-}" _ecb_b="${2:-}"
  [ -n "$_ecb_ov" ] && [ -s "$_ecb_b/checkpoint-brief.md" ] || return 1
  command -v sp_render >/dev/null 2>&1 || return 1
  # The brief rides in CKPT_RESUME_NOTE, a name sp_render already substitutes.
  local CKPT_RESUME_NOTE
  CKPT_RESUME_NOTE=$(cat "$_ecb_b/checkpoint-brief.md" 2>/dev/null) || return 1
  sp_render execute-resume "$_ecb_ov" 2>/dev/null
}

ecb_start_prompt() {
  local ov="${1:-}" ck
  [ -n "$ov" ] && [ -n "${BUILD:-}" ] && [ -n "${PROJECT:-}" ] && [ -n "${BUILD_CALL_FP:-}" ] || return 1
  ck=$(ecb_get_checkpoint "$PROJECT" "$BUILD_CALL_FP") || return 1
  ecb_write "$BUILD" "${BRANCH:-}" "${BASE:-}" || return 1
  ecb_render_resume "$ov" "$BUILD" || return 1
  ECB_START_CHECKPOINT="$ck"
  return 0
}
