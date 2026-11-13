#!/bin/bash
# bin/lib/hotfix-migrate-knobs.sh: the per-project settings row of the
# before-merge migration apply (BH-9403). Sourced by bin/hotfix-migrate.sh, by
# the `# >>> hotfix migrate stage` block of bin/lib/rb/result.sh and by the
# merge-conductor fragment bh-9403-before-merge-proof.sh. Never executed.
#
# THE ROW. hotfix_migrate.conf.<project> holds one JSON object. Every key is
# optional. A key that is present and valid BEATS the env-file knob of the same
# meaning (env/<project>.env); an absent key leaves the env value, then the code
# default, exactly as before this row existed.
#
#   key            exports                      valid value
#   workflow       HOTFIX_MIGRATE_WORKFLOW      <name>.yml / <name>.yaml
#   files_input    HOTFIX_WORKFLOW_FILES_INPUT  [A-Za-z0-9_-]{1,64}
#   max_files      HOTFIX_WORKFLOW_MAX_FILES    integer 1..50
#   dispatch_ref   HMK_DISPATCH_REF             [A-Za-z0-9._/-]{1,100}
#                  (default: the PR branch, today's dispatch)
#   branch_input   HMK_BRANCH_INPUT             [A-Za-z0-9._/-]{1,100}
#                  (the -f input that carries the PR branch; default: none)
#   file_form      HMK_FILE_FORM                path | basename (default path)
#   glob           HMK_GLOB                     <dir>/*.sql, relative, no ..
#   per_file       HMK_PER_FILE                 0 | 1 (default 0)
#   approve_head   HMK_APPROVE_HEAD             0 | 1 (default 0)
#   before_merge   HMK_BEFORE_MERGE             0 | 1 (default 0)
#   needs_quiet    HMK_NEEDS_QUIET              off (default: the command)
#   local_gate     HMK_LOCAL_GATE               strict | advisory (default strict)
#   gate_workflows HMK_GATE_WORKFLOWS           space list of workflow files
#   log_cap_kb     HMK_LOG_CAP_KB               integer 1..65536 (default 2048)
#   require_word   HMK_REQUIRE_WORD             0 | 1 (default 0). 1 = the workflow
#                  always names the file it applied, so in per-file mode a green
#                  run with no word about OUR file is `failed`, never `applied`
#                  (it can be another dispatch's run). 0 keeps today's meaning.
#   dispatch_lock_s HOTFIX_DISPATCH_LOCK_WAIT   integer 1..3600 (default 120): how
#                  long a dispatch waits for another dispatch of the same
#                  (repo, workflow, ref) to locate its run (hm_wf_dispatch_lock)
#
# HMK_GATE_CHECKS is read from a second row, mc.migration_gate_checks.<project>
# (BH-9368's row: the check names that are the migration-ledger gate itself).
#
# AN INVALID KEY IS IGNORED with one stderr line. It never reaches a dispatch.
# An unreadable or absent row sets no key, so the env values and the defaults
# stay, as they did before the row existed. HMK_SRC says which case it was:
# row | none | unreadable | no-client | invalid-json | no-project.
#
#   Set it: bin/jobs-client.sh setting-set hotfix_migrate.conf.<project> '<json>'
#   Kill switch for the before-merge apply: set "before_merge":0, or the row to {}.
#
# hmk_conf <project>        reads the rows, exports the values. rc 0 always.
# hmk_before_merge <project> rc 0 when the row has "before_merge":1. It reads in
#                           a subshell, so it exports nothing into the caller.

_hmk_ensure_client() {
  local h pf
  command -v setting_get >/dev/null 2>&1 && return 0
  h="${HARNESS:-${H:-}}"
  [ -n "$h" ] && [ -r "$h/bin/jobs-client.sh" ] || return 1
  pf=$(set -o 2>/dev/null | awk '$1=="pipefail"{print $2}')
  # shellcheck disable=SC1091
  . "$h/bin/jobs-client.sh" >/dev/null 2>&1 || true
  [ "$pf" = off ] && set +o pipefail
  command -v setting_get >/dev/null 2>&1
}

# _hmk_ok <key> <value>: rc 0 when the value is valid for the key.
_hmk_ok() {
  local k="$1" v="$2" w
  case "$k" in
    workflow)      grep -qxE '[A-Za-z0-9._-]+\.ya?ml' <<<"$v" ;;
    files_input)   grep -qxE '[A-Za-z0-9_-]{1,64}' <<<"$v" ;;
    dispatch_ref|branch_input)
                   grep -qxE '[A-Za-z0-9._/-]{1,100}' <<<"$v" || return 1
                   case "/$v/" in */../*) return 1 ;; esac ;;
    file_form)     case "$v" in path|basename) return 0 ;; esac; return 1 ;;
    max_files)     grep -qxE '[0-9]{1,2}' <<<"$v" && [ "$v" -ge 1 ] && [ "$v" -le 50 ] ;;
    dispatch_lock_s) grep -qxE '[0-9]{1,4}' <<<"$v" && [ "$v" -ge 1 ] && [ "$v" -le 3600 ] ;;
    log_cap_kb)    grep -qxE '[0-9]{1,5}' <<<"$v" && [ "$v" -ge 1 ] && [ "$v" -le 65536 ] ;;
    per_file|approve_head|before_merge|require_word) case "$v" in 0|1) return 0 ;; esac; return 1 ;;
    glob)          grep -qxE '[A-Za-z0-9_][A-Za-z0-9_.-]*(/[A-Za-z0-9_][A-Za-z0-9_.-]*)*/\*\.sql' <<<"$v" || return 1
                   case "/$v/" in */../*) return 1 ;; esac ;;
    needs_quiet)   [ "$v" = off ] ;;
    local_gate)    case "$v" in strict|advisory) return 0 ;; esac; return 1 ;;
    gate_workflows)
                   [ -n "$v" ] || return 1
                   for w in $v; do grep -qxE '[A-Za-z0-9._-]+\.ya?ml' <<<"$w" || return 1; done ;;
    gate_checks)   grep -qxE '[A-Za-z0-9 ._/:()-]{0,400}' <<<"$v" ;;
    *) return 1 ;;
  esac
}

hmk_conf() {
  local p="${1:-}" key v rc=0 k var
  HMK_DISPATCH_REF=""; HMK_BRANCH_INPUT=""; HMK_FILE_FORM=""; HMK_GLOB=""
  HMK_PER_FILE=""; HMK_APPROVE_HEAD=""; HMK_BEFORE_MERGE=""; HMK_NEEDS_QUIET=""
  HMK_LOCAL_GATE=""; HMK_GATE_WORKFLOWS=""; HMK_LOG_CAP_KB=""; HMK_GATE_CHECKS=""
  HMK_REQUIRE_WORD=""
  HMK_SRC=""
  case "$p" in ''|-) HMK_SRC=no-project; return 0 ;; esac
  _hmk_ensure_client || { HMK_SRC=no-client; return 0; }
  key="hotfix_migrate.conf.$p"
  v=$(setting_get "$key") || rc=$?
  case "$rc" in
    0) ;;
    2) HMK_SRC=none ;;
    *) HMK_SRC=unreadable
       echo "hotfix-migrate-knobs: $key unreadable (setting_get rc $rc); using the env values" >&2 ;;
  esac
  if [ "$rc" = 0 ]; then
    if ! jq -e 'type == "object"' >/dev/null 2>&1 <<<"$v"; then
      HMK_SRC=invalid-json
      echo "hotfix-migrate-knobs: $key is not a JSON object; using the env values" >&2
    else
      HMK_SRC=row
      for k in workflow files_input max_files dispatch_ref branch_input file_form glob \
               per_file approve_head before_merge needs_quiet local_gate gate_workflows log_cap_kb \
               require_word dispatch_lock_s; do
        jq -e --arg k "$k" 'has($k)' >/dev/null 2>&1 <<<"$v" || continue
        local val
        val=$(jq -r --arg k "$k" '.[$k] | if type == "string" or type == "number" then tostring else "\u0000bad" end' <<<"$v" 2>/dev/null)
        if ! _hmk_ok "$k" "$val"; then
          echo "hotfix-migrate-knobs: $key key '$k' value '$val' is not valid; ignored" >&2
          continue
        fi
        case "$k" in
          workflow)       var=HOTFIX_MIGRATE_WORKFLOW ;;
          files_input)    var=HOTFIX_WORKFLOW_FILES_INPUT ;;
          max_files)      var=HOTFIX_WORKFLOW_MAX_FILES ;;
          dispatch_ref)   var=HMK_DISPATCH_REF ;;
          branch_input)   var=HMK_BRANCH_INPUT ;;
          file_form)      var=HMK_FILE_FORM ;;
          glob)           var=HMK_GLOB ;;
          per_file)       var=HMK_PER_FILE ;;
          approve_head)   var=HMK_APPROVE_HEAD ;;
          before_merge)   var=HMK_BEFORE_MERGE ;;
          needs_quiet)    var=HMK_NEEDS_QUIET ;;
          local_gate)     var=HMK_LOCAL_GATE ;;
          gate_workflows) var=HMK_GATE_WORKFLOWS ;;
          log_cap_kb)     var=HMK_LOG_CAP_KB ;;
          require_word)   var=HMK_REQUIRE_WORD ;;
          dispatch_lock_s) var=HOTFIX_DISPATCH_LOCK_WAIT ;;
        esac
        printf -v "$var" '%s' "$val"
        # shellcheck disable=SC2163
        export "$var"
      done
    fi
  fi
  # BH-9368's row: the checks that ARE the migration-ledger gate. Red until the
  # SQL is applied, so the before-merge checks wait must not wait on them.
  rc=0; v=$(setting_get "mc.migration_gate_checks.$p" 2>/dev/null) || rc=$?
  if [ "$rc" = 0 ] && [ -n "$v" ]; then
    if _hmk_ok gate_checks "$v"; then HMK_GATE_CHECKS="$v"
    else echo "hotfix-migrate-knobs: mc.migration_gate_checks.$p value is not a list of check names; ignored" >&2
    fi
  fi
  export HMK_DISPATCH_REF HMK_BRANCH_INPUT HMK_FILE_FORM HMK_GLOB HMK_PER_FILE HMK_APPROVE_HEAD \
         HMK_BEFORE_MERGE HMK_NEEDS_QUIET HMK_LOCAL_GATE HMK_GATE_WORKFLOWS HMK_LOG_CAP_KB HMK_GATE_CHECKS HMK_REQUIRE_WORD
  return 0
}

hmk_before_merge() {
  ( hmk_conf "${1:-}" 2>/dev/null; [ "${HMK_BEFORE_MERGE:-}" = 1 ] )
}
