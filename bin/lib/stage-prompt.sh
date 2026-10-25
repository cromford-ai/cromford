# bin/lib/stage-prompt.sh — render a stage prompt template (BH-7970, BH-7940.2).
#
# The plan, execute, review, fix-round and qa stage prompts live in
# prompts/stages/<kind>.md. `sp_render <kind> [<outvar>]` renders one:
#
#   1. Source file: $HARNESS/state/prompts/$PROJECT/<kind>.md (the hub-resolved
#      copy) when it is readable and not empty, else $SP_STAGES_DIR/<kind>.md.
#      Neither readable: "stage-prompt: no template for <kind>" on stderr, rc 1,
#      nothing assigned. The caller stops the stage; it never sends an empty prompt.
#   2. SP_SOURCE_<kind> (dash as underscore: SP_SOURCE_fix_round) names the file read.
#   3. One left-to-right pass replaces each ${NAME} whose NAME is a word of
#      SP_VARS with that variable's value (empty when unset). Any other text,
#      ${HARNESS_SECRET}, ${KEY:-x}, $KEY with no braces, stays literal. A value
#      is never scanned again, and nothing is evaluated.
#   4. A non-empty $HARNESS/state/prompts/$PROJECT/rules.md puts one line in front:
#      "PROJECT RULES OVERRIDE: read <path>; it replaces ~/.claude/CLAUDE.md for this build."
#   5. With <outvar> the result goes there (printf -v), else to stdout. The
#      bytes of the file are kept: no trailing newline is added or removed.
#
# Unknown kind: rc 2. docs/PROMPTS.md "## Stage prompt files (BH-7940.2)".
# shellcheck shell=bash

# The only names a template can read. A fixed list, never a glob, so a template
# edited on the hub cannot read ${HARNESS_SECRET} or any other env value.
SP_VARS="KEY TICKET PROJECT BUILD BRANCH BASE SPEC_DIR GATES_NOTE CP_PREAMBLE UI_PLAN_NOTE
PLAN_AMBIGUITY_RULE REPLAN_LINE REVERT_REASON_LINE REOPEN_REASON_LINE KIND_HINT_LINE
CARRIED_NOTE_LINE REPRO_BRIEF_LINE CKPT_RESUME_NOTE KIND_EXEC_NOTE REROUTE_EXEC_NOTE
SP_PREVIEW_URL SP_PLAN_TH_RULE SP_PLAN_FRAGMENT_RULE SP_PLAN_UI_NOTICE SP_PLAN_DUP_MAIN
SP_PLAN_XREPO SP_PLAN_PFM SP_PLAN_PT SP_PLAN_VL SP_PLAN_SIZE_SCOPE SP_REVIEW_NH_FIELD
SP_REVIEW_DL_FIELD SP_REVIEW_NH_RELEASE SP_REVIEW_RL"

# The repo templates sit beside this lib's own checkout (physical path), so a
# test that points HARNESS at a scratch tree still finds them. SP_STAGES_DIR
# overrides it.
_SP_ROOT=$(cd -P "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)

sp_render() {
  local _sp_kind=${1-} _sp_outvar=${2-} _sp_dir _sp_f _sp_res _sp_body _sp_out _sp_name _sp_rules
  case "$_sp_kind" in
    plan|execute|review|fix-round|qa) ;;
    *) echo "stage-prompt: unknown kind '$_sp_kind'" >&2; return 2 ;;
  esac
  _sp_dir=${SP_STAGES_DIR:-$_SP_ROOT/prompts/stages}
  _sp_res="${HARNESS:-${H:-}}/state/prompts/${PROJECT:-}/$_sp_kind.md"
  if [ -n "${PROJECT:-}" ] && [ -s "$_sp_res" ] && [ -r "$_sp_res" ]; then
    _sp_f=$_sp_res
  elif [ -r "$_sp_dir/$_sp_kind.md" ] && [ -f "$_sp_dir/$_sp_kind.md" ]; then
    _sp_f=$_sp_dir/$_sp_kind.md
  else
    echo "stage-prompt: no template for $_sp_kind" >&2
    return 1
  fi
  # The trailing x keeps the file's own final newlines, which $() would strip.
  _sp_body=$(cat -- "$_sp_f" && printf x) || { echo "stage-prompt: cannot read $_sp_f" >&2; return 1; }
  _sp_body=${_sp_body%x}

  _sp_out=
  while [[ $_sp_body == *'${'* ]]; do
    _sp_out+=${_sp_body%%'${'*}
    _sp_body=${_sp_body#*'${'}
    _sp_name=${_sp_body%%\}*}
    if [[ $_sp_body == *\}* && $_sp_name =~ ^[A-Za-z_][A-Za-z0-9_]*$ && " ${SP_VARS//$'\n'/ } " == *" $_sp_name "* ]]; then
      _sp_out+=${!_sp_name-}
      _sp_body=${_sp_body#*\}}
    else
      _sp_out+='${'
    fi
  done
  _sp_out+=$_sp_body

  _sp_rules="${HARNESS:-${H:-}}/state/prompts/${PROJECT:-}/rules.md"
  if [ -n "${PROJECT:-}" ] && [ -s "$_sp_rules" ]; then
    _sp_out="PROJECT RULES OVERRIDE: read $_sp_rules; it replaces ~/.claude/CLAUDE.md for this build."$'\n'"$_sp_out"
  fi

  printf -v "SP_SOURCE_${_sp_kind//-/_}" '%s' "$_sp_f"
  if [ -n "$_sp_outvar" ]; then printf -v "$_sp_outvar" '%s' "$_sp_out"; else printf '%s' "$_sp_out"; fi
}
