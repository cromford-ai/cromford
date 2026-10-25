#!/bin/bash
# bin/lib/web-human.sh — BH-7598 (slice C0): a person completes a 2FA step of
# a web-task run. The client half of worker/jobs/src/routes/web-task-human.js.
# Sourced, never run; functions only. Contract:
# docs/notes/2026-10-23-BH-7598-web-task-human.md.
#
#   wh_request_human <project> <site> <code|approve> <prompt> [--shot <png>] [--issue <owner/repo#n>]
#     The ticket's request_human(kind, prompt), for a claimed web-task lane run.
#     1. POSTs /api/web-task/human/ask (the run binding of wv_read: run_id,
#        machine, x-web-vault-run-token). A new ask of the same run makes the
#        run's older open step "old".
#     2. Sends ONE Telegram message (bin/lib/web-human/telegram.sh) to the
#        chat the worker names, with the screenshot when --shot is given, and
#        posts ONE `NEEDS-HUMAN:` comment on --issue (bin/lib/web-human/board.sh).
#        Each outcome is one stderr line, `web-human: telegram: <outcome>` and
#        `web-human: board: <outcome>`. If neither delivered, the step is
#        cancelled and rc is 1 (`web-human: no channel delivered the ask`).
#     3. Polls every poll_s until wait_until (both from the worker's settings
#        rows; WEB_TASK_HUMAN_WAIT_S may only shorten the wait). Between polls
#        it reads the issue for a `HUMAN-STEP-DONE: <code|done>` comment by a
#        login of web_task.human_logins and hands it to /api/web-task/answer
#        (via=board), so the answer route stays the one writer.
#     rc 0: the code on stdout with no newline (kind code), or `done` (kind approve).
#     rc 3: `web-human: cancelled` on stderr (a person pressed Cancel).
#     rc 4: `web-human: waiting on human (step <id>)` on stderr, nothing on
#           stdout; the step stays open until its expires_at, so a later
#           answer is kept for the resume run.
#     rc 1: a refusal (`web-human: refused <why>`), the worker unreachable, no
#           channel delivered, or a poll that failed.
#     rc 2: usage, or no LANE_RUN_ID, machine, WEB_VAULT_RUN_TOKEN, JOBS_URL or
#           HARNESS_SECRET; no request is sent.
#     The code is held in a local variable and goes out by printf (a builtin)
#     and on curl's stdin only: never on an argv, in a file, a log or a prompt.
#
# Needs curl, jq and GNU date. Reads TELEGRAM_BOT_TOKEN (unset: the Telegram
# channel is not-configured) and the env of wv_read from the environment only.

__wh_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
if ! declare -F wv_curl_cfg >/dev/null; then
  # shellcheck source=bin/lib/web-vault.sh
  . "$__wh_dir/web-vault.sh" || { echo "web-human: bin/lib/web-vault.sh did not load" >&2; return 1; }
fi
# shellcheck source=bin/lib/web-human/telegram.sh
. "$__wh_dir/web-human/telegram.sh" || { echo "web-human: bin/lib/web-human/telegram.sh did not load" >&2; return 1; }
# shellcheck source=bin/lib/web-human/board.sh
. "$__wh_dir/web-human/board.sh" || { echo "web-human: bin/lib/web-human/board.sh did not load" >&2; return 1; }

# The box-side HTTP timeouts are lib knobs (catalog/lanes.d/_lib.web-human.json,
# rows lib.web-human.web_human_timeout_s and lib.web-human.web_human_connect_timeout_s).
# A caller that loaded bin/lib/lane-gate.sh gets the rows; else the env or the fallback.
if declare -F lib_env_apply >/dev/null; then lib_env_apply web-human || true; fi

# _wh_post <path> [run] — POST stdin to the worker; prints the body, a
# newline and the HTTP code. rc 1 when the worker is unreachable.
_wh_post() {
  curl -sS -m "${WEB_HUMAN_TIMEOUT_S:-15}" --connect-timeout "${WEB_HUMAN_CONNECT_TIMEOUT_S:-5}" -w $'\n%{http_code}' -K <(wv_curl_cfg "${2:-}") \
    -H 'content-type: application/json' -X POST --data-binary @- "$JOBS_URL$1" 2>/dev/null
}

# _wh_answer <step> <action> <via> — POST /api/web-task/answer for this run.
# stdin: the nonce, a newline, then the code (or nothing), so neither is on
# an argv. Prints the body, a newline and the HTTP code.
_wh_answer() {
  jq -Rsc --argjson run "$LANE_RUN_ID" --argjson step "$1" --arg action "$2" --arg via "$3" '
      (index("\n")) as $i | .[0:$i] as $nonce | .[$i + 1:] as $code
      | {run_id: $run, step_id: $step, nonce: $nonce, action: $action, via: $via}
        + (if $action == "code" then {code: $code} else {} end)' \
    | _wh_post /api/web-task/answer
}

wh_request_human() {
  local project="${1:-}" site="${2:-}" kind="${3:-}" prompt="${4:-}" shot="" issue="" repo="" num=""
  local machine="${WEB_VAULT_MACHINE:-${FLY_MACHINE_ID:-}}" run="${LANE_RUN_ID:-}"
  local out code body why step nonce wait_until poll_s tg_chat logins text tg board since
  local deadline now first=1 errs=0 state action hit nap unread=0 rc
  if [ "$#" -lt 4 ] || [ -z "$project" ] || [ -z "$site" ] || [ -z "$prompt" ]; then
    echo "web-human: usage: wh_request_human <project> <site> <code|approve> <prompt> [--shot <png>] [--issue <owner/repo#n>]" >&2; return 2
  fi
  shift 4
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --shot) shot="${2:-}"; shift 2 || { echo "web-human: --shot needs a path" >&2; return 2; } ;;
      --issue) issue="${2:-}"; shift 2 || { echo "web-human: --issue needs <owner/repo#n>" >&2; return 2; } ;;
      *) echo "web-human: unknown argument: $1" >&2; return 2 ;;
    esac
  done
  case "$kind" in code|approve) ;; *) echo "web-human: kind is code or approve, not '$kind'" >&2; return 2 ;; esac
  if [ -n "$shot" ] && [ ! -s "$shot" ]; then echo "web-human: no screenshot at $shot" >&2; return 2; fi
  if [ -n "$issue" ]; then
    [[ $issue =~ ^([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)#([1-9][0-9]{0,9})$ ]] || { echo "web-human: --issue is <owner/repo#n>, not '$issue'" >&2; return 2; }
    repo="${BASH_REMATCH[1]}"; num="${BASH_REMATCH[2]}"
  fi
  [[ $run =~ ^[1-9][0-9]{0,15}$ ]] || { echo "web-human: no LANE_RUN_ID (wh_request_human runs inside a lane run)" >&2; return 2; }
  [ -n "$machine" ] || { echo "web-human: no machine id (WEB_VAULT_MACHINE or FLY_MACHINE_ID)" >&2; return 2; }
  [ -n "${WEB_VAULT_RUN_TOKEN:-}" ] || { echo "web-human: no WEB_VAULT_RUN_TOKEN (the claim of this run gave none)" >&2; return 2; }
  [ -n "${JOBS_URL:-}" ] || { echo "web-human: not-configured: JOBS_URL" >&2; return 2; }
  [ -n "${HARNESS_SECRET:-}" ] || { echo "web-human: not-configured: HARNESS_SECRET" >&2; return 2; }

  # 1. The ask.
  out=$(jq -nc --argjson run_id "$run" --arg machine "$machine" --arg project "$project" --arg site "$site" \
          --arg kind "$kind" --arg prompt "$prompt" \
          '{run_id:$run_id, machine:$machine, project:$project, site:$site, kind:$kind, prompt:$prompt}' \
        | _wh_post /api/web-task/human/ask run) || { echo "web-human: worker unreachable" >&2; return 1; }
  code="${out##*$'\n'}"; body="${out%$'\n'*}"
  if [ "$code" != 200 ]; then
    why=$(printf '%s' "$body" | jq -r '.refused // empty' 2>/dev/null)
    if [ -n "$why" ]; then echo "web-human: refused $why" >&2
    else echo "web-human: $code $(printf '%s' "$body" | jq -r '.error // empty' 2>/dev/null)" >&2; fi
    return 1
  fi
  # The separator is US (0x1f), not tab: tab is IFS whitespace, so read would
  # collapse an empty tg_chat (no chat row) and shift logins into it.
  IFS=$'\x1f' read -r step nonce wait_until poll_s tg_chat logins < <(printf '%s' "$body" \
    | jq -r '[.step_id, .nonce, .wait_until, .poll_s, (.tg_chat // ""), ((.logins // []) | join(","))] | map(tostring) | join("\u001f")' 2>/dev/null)
  if ! [[ ${step:-} =~ ^[1-9][0-9]{0,15}$ && ${nonce:-} =~ ^[A-Za-z0-9_-]{22}$ && ${poll_s:-} =~ ^[1-9][0-9]*$
          && ${wait_until:-} =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then
    echo "web-human: the worker answered 200 with no step" >&2; return 1
  fi

  # 2. The two channels. The step row exists already, so a failed send leaves
  # an answerable step on the other channel.
  if [ "$kind" = code ]; then
    text=$(printf 'web-task needs a person\nProject: %s\nSite: %s\nStep: %s\nReply to this message with the code, or press Cancel.\nref: wt:%s:%s' \
      "$project" "$site" "$prompt" "$step" "$nonce")
  else
    text=$(printf 'web-task needs a person\nProject: %s\nSite: %s\nStep: %s\nApprove it on the device, then press Done. Press Cancel to stop.\nref: wt:%s:%s' \
      "$project" "$site" "$prompt" "$step" "$nonce")
  fi
  tg=$(wht_send "$tg_chat" "$kind" "$text" "$step" "$nonce" "$shot")
  echo "web-human: telegram: $tg" >&2
  if [ -n "$issue" ]; then
    local how
    if [ "$kind" = code ]; then how='reply to my Telegram message with the code, or press Cancel. Or post a comment here whose first line is `HUMAN-STEP-DONE: <the code>`.'
    else how='approve it on the device, then press Done on my Telegram message. Or post a comment here whose first line is `HUMAN-STEP-DONE: done`.'; fi
    board=$(whb_post "$repo" "$num" "$(printf 'NEEDS-HUMAN: web-task %s on %s: %s\n\nRun %s of %s waits for a person until %s. To answer, %s\n\n<!-- wt-step:%s -->\n' \
      "$kind" "$site" "$prompt" "$run" "$project" "$wait_until" "$how" "$step")")
  else
    board="not-configured: issue"
  fi
  echo "web-human: board: $board" >&2
  if [[ $tg != "sent "* && $board != "posted "* ]]; then
    printf '%s\n' "$nonce" | _wh_answer "$step" cancel api >/dev/null
    echo "web-human: no channel delivered the ask" >&2; return 1
  fi
  [[ $board == "posted "* ]] && since="${board##* }" || since=""

  # 3. The wait.
  now=$(date -u +%s)
  { [ -n "$wait_until" ] && deadline=$(date -u -d "$wait_until" +%s 2>/dev/null); } || deadline=$now
  if [[ ${WEB_TASK_HUMAN_WAIT_S:-} =~ ^[0-9]+$ ]] && [ $((now + WEB_TASK_HUMAN_WAIT_S)) -lt "$deadline" ]; then
    deadline=$((now + WEB_TASK_HUMAN_WAIT_S))
  fi
  while :; do
    if [ "$first" = 1 ]; then
      out=$(jq -nc --argjson run_id "$run" --arg machine "$machine" --argjson step_id "$step" --arg tg "$tg" --arg board "$board" \
              '{run_id:$run_id, machine:$machine, step_id:$step_id, tg_outcome:$tg[0:200], board_outcome:$board[0:200]}' \
            | _wh_post /api/web-task/human/poll run)
    else
      out=$(jq -nc --argjson run_id "$run" --arg machine "$machine" --argjson step_id "$step" \
              '{run_id:$run_id, machine:$machine, step_id:$step_id}' | _wh_post /api/web-task/human/poll run)
    fi
    if [ $? != 0 ]; then
      errs=$((errs + 1)); echo "web-human: poll failed: worker unreachable" >&2
    else
      code="${out##*$'\n'}"; body="${out%$'\n'*}"
      if [ "$code" = 200 ]; then
        first=0
        state=$(printf '%s' "$body" | jq -r '.state // empty' 2>/dev/null)
        case "$state" in
          pending) ;;
          answered)
            action=$(printf '%s' "$body" | jq -r '.action // empty' 2>/dev/null)
            if [ "$action" = code ]; then
              local c
              c=$(printf '%s' "$body" | jq -j 'if (.code | type) == "string" then .code else empty end' 2>/dev/null)
              [ -n "$c" ] || { echo "web-human: the worker answered with no code" >&2; return 1; }
              printf '%s' "$c"; unset c
              return 0
            fi
            [ "$action" = done ] && { printf 'done'; return 0; }
            echo "web-human: the worker answered an unknown action" >&2; return 1 ;;
          cancelled) echo "web-human: cancelled" >&2; return 3 ;;
          consumed) echo "web-human: step $step was consumed by another poll" >&2; return 1 ;;
          *) errs=$((errs + 1)); echo "web-human: poll failed: no state" >&2 ;;
        esac
      elif why=$(printf '%s' "$body" | jq -r '.refused // empty' 2>/dev/null) && [ -n "$why" ]; then
        echo "web-human: refused $why" >&2; return 1
      elif [[ $code == 4* ]]; then
        # A 4xx is this client's bug, not an outage: a retry gets the same answer.
        echo "web-human: poll $code $(printf '%s' "$body" | jq -r '.error // empty' 2>/dev/null)" >&2; return 1
      else
        errs=$((errs + 1)); echo "web-human: poll failed: $code" >&2
      fi
    fi
    if [ -n "$since" ]; then
      hit=$(whb_done_after "$repo" "$num" "$since" "$logins"); rc=$?
      if [ "$rc" = 0 ] && [ -n "$hit" ]; then
        if [ "$kind" = code ]; then out=$(printf '%s\n%s' "$nonce" "$hit" | _wh_answer "$step" code board)
        else out=$(printf '%s\n' "$nonce" | _wh_answer "$step" done board); fi
        unset hit
        code="${out##*$'\n'}"
        # An accepted board answer is read by the next poll at once.
        [ "$code" = 200 ] && continue
        echo "web-human: board answer not taken: $(printf '%s' "${out%$'\n'*}" | jq -r '.refused // .error // empty' 2>/dev/null)" >&2
      elif [ "$rc" = 2 ] && [ "$unread" = 0 ]; then
        unread=1; echo "web-human: board unreadable; Telegram still answers" >&2
      fi
    fi
    now=$(date -u +%s)
    [ "$now" -lt "$deadline" ] || break
    nap=$((deadline - now)); [ "$nap" -gt "$poll_s" ] && nap=$poll_s
    sleep "$nap"
  done
  if [ "$errs" -gt 0 ]; then
    echo "web-human: $errs polls failed; step $step stays open" >&2; return 1
  fi
  echo "web-human: waiting on human (step $step)" >&2
  return 4
}
