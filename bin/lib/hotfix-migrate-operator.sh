#!/bin/bash
# bin/lib/hotfix-migrate-operator.sh: the `needs-operator` stop of the
# before-merge migration apply (BH-9817). Sourced by bin/hotfix-migrate.sh next
# to bin/lib/hotfix-migrate-workflow.sh, never executed.
#
# A `needs-operator` stop is for a PR the apply workflow can NEVER take on its
# own, so a re-run of the stage cannot clear it and a person must act:
#   outside-allowlist  in local_gate=advisory mode, a statement the local gate
#                      FLAGGED starts with a keyword on the project's workflow
#                      refuse list (GRANT, UPDATE, DO ...). The workflow refuses
#                      it on every run, so we do not approve or dispatch.
#   approve-422        GitHub answered 422 to the APPROVED review on this head
#                      (for example "Can not approve your own pull request").
#                      Terminal for that head; a new head is tried again.
# The proof marker says decision=needs-operator. The conductor parks the PR
# (mc_hotfix_proof reads it as `hold`) until the production ledger lists the
# file (mc_bm_operator_applied releases it then), and bin/merge-conductor.d/
# bh-9817-held-operator-alert.sh raises one alert a day once it is held longer
# than the row hotfix_migrate.held_alert_hours.
#
# The comment carries one `Operator step (<path>): <step>` line per file. The
# conductor alert reads those lines, so each step stays on ONE line. No text
# here names a comment command: the step is the project's own runbook step
# (row hotfix_migrate.operator_step.<project>) or the plain fallback below.
#
# FROM THE STAGE it uses: hm_wf_body, hm_wf_pf_json, hm_wf_files_json, hm_finish
# and the globals PROJECT SLUG BRANCH FP FILES LEDGER HM_BEFORE_MERGE. From
# hm_workflow_body (approve-422 only): WF INPUT DREF and HM_WF_APPROVE_*.

# The code fallback of the row hotfix_migrate.workflow_refuses.<project>, used
# only when that row is absent or invalid. It is what project-6's own
# src/lib/migrations/branch-allowlist.ts refuses.
HM_OP_REFUSES_DEFAULT='GRANT,REVOKE,UPDATE,DELETE,DROP,TRUNCATE,DO,SET,COMMENT,CREATE POLICY,CREATE FUNCTION,CREATE OR REPLACE FUNCTION,CREATE VIEW,CREATE OR REPLACE VIEW,CREATE TRIGGER,CREATE EXTENSION'

# hm_op_refuses <gate-report>: print the FLAGGED lines whose statement starts
# with a refused keyword. rc 0 = at least one; rc 1 = none (or no report).
# The keyword must be the whole first word(s): `UPDATED_AT` and `DOMAIN` do not
# match UPDATE and DO, and a keyword later in the statement does not count.
hm_op_refuses() {
  local rep="$1" list re item line snip U hit=1
  [ -r "$rep" ] || return 1
  list="${HMK_WORKFLOW_REFUSES:-$HM_OP_REFUSES_DEFAULT}"
  re=""
  local IFS=,
  for item in $list; do
    item=$(printf '%s' "$item" | sed -E 's/^ +//; s/ +$//; s/ +/[[:space:]]+/g')
    [ -n "$item" ] && re="${re:+$re|}$item"
  done
  unset IFS
  [ -n "$re" ] || return 1
  while IFS= read -r line; do
    snip=$(sed -nE 's/^[^:]*: FLAGGED \([^)]*\): //p' <<<"$line")
    [ -n "$snip" ] || continue
    U=$(tr '[:lower:]' '[:upper:]' <<<"$snip" | sed -E 's/^[[:space:]]+//')
    if grep -qE "^($re)([[:space:](;]|\$)" <<<"$U"; then
      printf '%s\n' "$line"; hit=0
    fi
  done < "$rep"
  return "$hit"
}

# hm_op_step <cause> <file>: the operator step for one file, on one line.
hm_op_step() {
  local cause="$1" f="$2" s tok
  if [ "$cause" = approve-422 ]; then
    tok="$f"; [ "${HMK_FILE_FORM:-path}" = basename ] && tok="${f##*/}"
    s="A person with write access approves head ${HM_WF_APPROVE_HEAD:0:12} on this PR, then runs: gh workflow run ${WF:-$HOTFIX_MIGRATE_WORKFLOW} -R $SLUG --ref ${DREF:-$BRANCH}"
    [ -n "${INPUT:-}" ] && s="$s -f $INPUT=$tok"
    [ -n "${HMK_BRANCH_INPUT:-}" ] && s="$s -f $HMK_BRANCH_INPUT=$BRANCH"
    printf '%s' "$s"
    return 0
  fi
  if [ -n "${HMK_OPERATOR_STEP:-}" ]; then
    s="$HMK_OPERATOR_STEP"
    s="${s//\{path\}/$f}"; s="${s//\{file\}/${f##*/}}"; s="${s//\{branch\}/$BRANCH}"
  else
    # Fallback of the row hotfix_migrate.operator_step.<project>.
    s="Apply $f by hand with $PROJECT's own apply runbook. ${HOTFIX_MIGRATE_WORKFLOW:-the migration workflow} cannot apply it: its allow-list refuses the statements above."
  fi
  printf '%s' "$s" | tr '\r\n' '  '
}

# hm_op_stop <cause> [matched-lines-file]: write the needs-operator ledger, post
# one proof comment, rc 3. Dedupe: when the ledger already holds needs-operator
# for this fp and cause (and, for approve-422, this head) with a posted comment,
# it posts nothing and returns 3. One comment per head or per SQL, never per tick.
hm_op_stop() {
  local cause="$1" matched="${2:-}" body fj note f i headline pid
  local HM_LEDGER_EXTRA
  # hm_wf_body reads these; hm_main has none of them before the workflow runs.
  local RUN_URL="${RUN_URL:-}" RUN_ID="${RUN_ID:-}" WORD="${WORD:-}" FSTAT="${FSTAT:-}"
  if [ -z "${QL+x}" ]; then
    local -a QL=()
    i=0; while [ "$i" -lt "${#FILES[@]}" ]; do QL+=("not checked (nothing was dispatched)"); i=$((i+1)); done
  fi
  if [ -s "$LEDGER" ]; then
    pid=$(jq -r --arg fp "$FP" --arg c "$cause" --arg h "${HM_WF_APPROVE_HEAD:-}" \
      'if .fp == $fp and .decision == "needs-operator" and (.cause // "") == $c
          and ($c != "approve-422" or (.approve_refused.head // "") == $h)
       then (.posted_comment_id // "null" | tostring) else "null" end' "$LEDGER" 2>/dev/null)
    if [ -n "$pid" ] && [ "$pid" != null ]; then
      echo "hotfix-migrate: needs-operator ($cause) already posted for this SQL (comment $pid); nothing new posted" >&2
      return 3
    fi
  fi
  if [ "$cause" = approve-422 ]; then
    headline="We held this PR and dispatched nothing: GitHub refused the approval on head ${HM_WF_APPROVE_HEAD:0:12}, and a re-run cannot change that."
    note="${HM_WF_APPROVE_WHY:-the approval did not post.}"
    HM_LEDGER_EXTRA=$(jq -cn --arg c "$cause" --arg h "${HM_WF_APPROVE_HEAD:-}" --arg s "${HM_WF_APPROVE_STATUS:-}" \
      --arg m "${HM_WF_APPROVE_MSG:-}" --argjson e "${HM_WF_APPROVE_ERRORS:-[]}" \
      '{cause:$c, approve_refused:{head:$h, status:(($s|tonumber?) // $s), message:$m, errors:$e}}' 2>/dev/null) \
      || HM_LEDGER_EXTRA=$(jq -cn --arg c "$cause" --arg h "${HM_WF_APPROVE_HEAD:-}" '{cause:$c, approve_refused:{head:$h, status:422}}')
  else
    headline="We held this PR and dispatched nothing: the migration workflow cannot apply this SQL, so a person applies it."
    note=$(printf 'These statements are outside what %s may apply (row hotfix_migrate.workflow_refuses.%s), so no run of it can ever apply this file. We did not approve or dispatch anything.\n\n```\n%s\n```' \
      "${HOTFIX_MIGRATE_WORKFLOW:-the workflow}" "$PROJECT" "$(head -c 1500 "$matched" 2>/dev/null)")
    HM_LEDGER_EXTRA=$(jq -cn --arg c "$cause" '{cause:$c}')
  fi
  for f in "${FILES[@]}"; do
    note=$(printf '%s\nOperator step (%s): %s' "$note" "$f" "$(hm_op_step "$cause" "$f")")
  done
  # The release is the merge conductor's (mc_bm_operator_applied): it asks the
  # production ledger every tick. A re-run of this stage on the same SQL stops
  # here again, so the text must not promise that.
  note=$(printf '%s\n\nAfter that, the merge conductor releases the PR on its next tick, once the production migration ledger (row mc_migration_hold.globs.%s) lists every file. A project with no such row has no automatic release: a person moves the PR on.' "$note" "$PROJECT")
  body=$(mktemp)
  hm_wf_body "$headline" "$note" > "$body"
  if [ "${HM_PF:-0}" = 1 ]; then fj=$(hm_wf_pf_json); else fj=$(hm_wf_files_json hold "$RUN_ID"); fi
  hm_finish needs-operator "$body" "$fj" 3
  local rc=$?; rm -f "$body"; return "$rc"
}

# hm_op_reviewer_login: the reviewer (hub) App's login, app/<slug>, from
# env/github-app.env, normalised the way bin/lib/gh-pr-list.sh's
# _hpl_app_login_from does it. No API call. Nothing printed = not known.
hm_op_reviewer_login() {
  local r="${HARNESS:-${H:-}}" d raw
  [ -n "$r" ] || return 0
  if declare -F harness_env_dir >/dev/null 2>&1; then d=$(harness_env_dir "$r"); else d="$r/env"; fi
  [ -r "$d/github-app.env" ] || return 0
  raw=$(sed -n 's/^\(export \)\{0,1\}GH_APP_SLUG=//p;s/^\(export \)\{0,1\}GH_APP_NAME=//p' "$d/github-app.env" 2>/dev/null \
        | tr -d "\"'" | head -n 1)
  raw=$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')
  [ -n "$raw" ] && printf 'app/%s\n' "$raw"
  return 0
}

# hm_op_login_norm <login>: `name[bot]` and `app/name` are one actor.
hm_op_login_norm() {
  local l="${1:-}"
  l="${l#app/}"; l="${l%\[bot\]}"
  [ -n "$l" ] && printf 'app/%s' "$(tr '[:upper:]' '[:lower:]' <<<"$l")"
}
