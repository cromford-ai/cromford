# shellcheck shell=bash
# bin/lib/human-gate.sh — human gates (BH-9559 part A): a question the harness
# asks a person, with a recommended answer, 1-3 reasons, a default and a
# deadline, recorded as one human_gates row in the jobs D1
# (worker/jobs/src/routes/human-gates.js). Sourced, never run; defines
# functions only. Doc: docs/CUSTODY.md "Human gates".
#
#   hg_class <reason>
#     prints defaultable only when the settings row human_gate.class.<reason>
#     is exactly defaultable; else irreversible (no row, an outage, a reason
#     outside [a-z0-9_-], an empty reason). rc 0.
#   hg_ask <repo> <key> <lane> <reason> <question> <recommended> <r1> [r2] [r3] -- <default>
#     rc 0 + the 5-field block on stdout: the row is written.
#     rc 0 + nothing: the kill flag human_gate.format.enabled is 0 (no POST).
#     rc 1 + nothing: the POST failed or the answer has no deadline_at.
#     rc 2 + one stderr line "hg_ask: refused: <why>": no POST.
#   hg_plan_blocked <repo> <key> <build-dir>
#     one hg_ask (lane plan, reason plan_blocked) per question of the plan's
#     client-questions block; every block goes to <build-dir>/human-gates.md,
#     numbered. All or nothing: any refusal or failure removes the file.
#     rc 0 written (or the kill flag is 0: no file), 1 a question failed,
#     3 no valid client-questions block.
#   hg_release <lane> <repo> <key> <answer>
#     sources bin/lib/human-gate-release.d/<lane>.sh and returns
#     hgr_<lane> <repo> <key> <answer>. rc 2 bad lane, rc 3 no lane file or
#     the file defines no hgr_<lane>.
#
# The jobs client is HG_JOBS_CLIENT, else $HARNESS/bin/jobs-client.sh. With no
# root and no HG_JOBS_CLIENT a read is "no answer" and a write is rc 1.

_hg_root() { printf '%s' "${HARNESS:-${H:-}}"; }
_hg_client() {
  if [ -n "${HG_JOBS_CLIENT:-}" ]; then printf '%s' "$HG_JOBS_CLIENT"; return 0; fi
  local r; r=$(_hg_root)
  [ -n "$r" ] && [ -x "$r/bin/jobs-client.sh" ] || return 1
  printf '%s' "$r/bin/jobs-client.sh"
}
# _hg_setting <key> — the row's value on stdout; rc != 0 when there is no answer.
_hg_setting() {
  local c; c=$(_hg_client) || return 1
  "$c" setting-get "$1" 2>/dev/null
}
_hg_blank() { [ -z "${1//[[:space:]]/}" ]; }
_hg_one() { printf '%s' "$1" | tr '\r\n\t' '   ' | tr -s ' ' | sed 's/^ //; s/ $//'; }

hg_class() {
  local reason="${1:-}" v
  case "$reason" in ''|*[!a-z0-9_-]*) echo irreversible; return 0 ;; esac
  v=$(_hg_setting "human_gate.class.$reason") || v=""
  if [ "$v" = defaultable ]; then echo defaultable; else echo irreversible; fi
  return 0
}

hg_ask() {
  local repo="${1:-}" key="${2:-}" lane="${3:-}" reason="${4:-}" q="${5:-}" rec="${6:-}"
  local def="" dashes=0 after=0 r body out c dl i
  local -a rs=()
  if [ $# -ge 6 ]; then shift 6; else shift $#; fi
  while [ $# -gt 0 ]; do
    if [ "$dashes" = 0 ] && [ "$1" = "--" ]; then dashes=1
    elif [ "$dashes" = 1 ]; then after=$((after+1)); def="$1"
    else rs+=("$1"); fi
    shift
  done
  # The kill flag: 0 means the caller keeps its old text. No row or an outage
  # reads as enabled (the seed is 1).
  [ "$(_hg_setting human_gate.format.enabled)" = 0 ] && return 0
  _hg_blank "$q" && { echo "hg_ask: refused: no question" >&2; return 2; }
  _hg_blank "$rec" && { echo "hg_ask: refused: no recommended answer" >&2; return 2; }
  [ "$dashes" = 1 ] || { echo "hg_ask: refused: no default (no -- before it)" >&2; return 2; }
  [ "$after" -le 1 ] || { echo "hg_ask: refused: $after values after --, want one default" >&2; return 2; }
  _hg_blank "$def" && { echo "hg_ask: refused: no default" >&2; return 2; }
  [ "${#rs[@]}" -ge 1 ] && [ "${#rs[@]}" -le 3 ] || { echo "hg_ask: refused: ${#rs[@]} reasons, want 1 to 3" >&2; return 2; }
  for r in "${rs[@]}"; do _hg_blank "$r" && { echo "hg_ask: refused: a blank reason" >&2; return 2; }; done
  c=$(_hg_client) || { echo "hg_ask: no jobs client (no HARNESS root)" >&2; return 1; }
  body=$(jq -nc --arg repo "$repo" --arg key "$key" --arg lane "$lane" --arg reason "$reason" \
    --arg q "$q" --arg rec "$rec" --arg def "$def" \
    '{repo:$repo,key:$key,lane:$lane,reason:$reason,question:$q,recommended:$rec,reasons:$ARGS.positional,default_answer:$def}' \
    --args "${rs[@]}" 2>/dev/null) || { echo "hg_ask: could not build the request body" >&2; return 1; }
  out=$("$c" human-gate-put "$body" 2>/dev/null) || { echo "hg_ask: POST /api/human-gates failed for $repo/$key ($lane)" >&2; return 1; }
  dl=$(jq -r '.gate.deadline_at // empty' <<<"$out" 2>/dev/null)
  [[ "$dl" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2} ]] \
    || { echo "hg_ask: the answer for $repo/$key ($lane) has no deadline_at" >&2; return 1; }
  local reasons="" sep=""
  for i in "${rs[@]}"; do reasons+="$sep$(_hg_one "$i")"; sep="; "; done
  printf 'Question: %s\nRecommended answer: %s\nReasons: %s\nDefault: %s\nDeadline (UTC): %s %s UTC\n' \
    "$(_hg_one "$q")" "$(_hg_one "$rec")" "$reasons" "$(_hg_one "$def")" "${dl:0:10}" "${dl:11:5}"
}

hg_plan_blocked() {
  local repo="${1:-}" key="${2:-}" b="${3:-}" _CQ_SRC="" n i out rc f
  [ -n "$b" ] && [ -d "$b" ] || return 3
  f="$b/human-gates.md"; rm -f "$f"
  command -v cq_check >/dev/null 2>&1 || . "${BASH_SOURCE[0]%/*}/client-questions.sh" 2>/dev/null
  command -v cq_check >/dev/null 2>&1 || return 3
  cq_check "$b/plan.md" 2>/dev/null || return 3
  [ "$(_hg_setting human_gate.format.enabled)" = 0 ] && { echo "human-gate: format flag is 0; no gate written"; return 0; }
  n=$(jq -r 'length' <<<"$_CQ_SRC" 2>/dev/null) || return 3
  local -a args
  for ((i = 0; i < n; i++)); do
    mapfile -t args < <(jq -r --argjson i "$i" '.[$i] | (.question, .recommended,
      ([.reasons[] | select(type == "string") | select(gsub("\\s"; "") != "")] | .[]), "--", .default)
      | tostring | gsub("[\\r\\n]+"; " ")' <<<"$_CQ_SRC" 2>/dev/null)
    out=$(hg_ask "$repo" "$key" plan plan_blocked "${args[@]}" 2>"$b/.hg-ask.err"); rc=$?
    if [ "$rc" != 0 ] || [ -z "$out" ]; then
      echo "human-gate: question $((i + 1)) not written (rc $rc): $(head -1 "$b/.hg-ask.err" 2>/dev/null); the comment keeps the plain questions"
      rm -f "$f" "$b/.hg-ask.err"
      return 1
    fi
    { [ "$i" = 0 ] || printf '\n'; printf '**%d.**\n%s\n' "$((i + 1))" "$out"; } >> "$f"
  done
  rm -f "$b/.hg-ask.err"
  echo "human-gate: $n gate(s) written for $repo/$key to $f"
  return 0
}

hg_release() {
  local lane="${1:-}" fn lf
  [[ "$lane" =~ ^[a-z][a-z-]*$ ]] || { echo "hg_release: refused lane '$lane'" >&2; return 2; }
  shift
  lf="${BASH_SOURCE[0]%/*}/human-gate-release.d/$lane.sh"
  [ -r "$lf" ] || { echo "hg_release: $lane: no lane file $lf" >&2; return 3; }
  fn="hgr_${lane//-/_}"
  # shellcheck source=/dev/null
  . "$lf" || { echo "hg_release: $lane: lane file did not load" >&2; return 3; }
  declare -F "$fn" >/dev/null || { echo "hg_release: $lane: lane file defines no $fn" >&2; return 3; }
  "$fn" "$@"
}
