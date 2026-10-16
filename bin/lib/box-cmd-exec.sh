#!/bin/bash
# shellcheck shell=bash
# bin/lib/box-cmd-exec.sh — BH-2655 (BH-2528.2). Runs ONE console command on the
# box that owns its project: bcx_run. The per-type bodies are the LOCAL branches
# of bin/poll-commands.sh's `# >>> <type> handler` blocks, minus the ssh forward
# (the row already reached the owning box) and minus the beat (the outcome goes
# back to the box_console_commands row, see bin/box-console-commands.sh).
#
# Sourced, never executed. Function definitions only.
#
# bcx_run <type> <project> <payload-json> <command_id>
#   Sets BCX_OK (1|0), BCX_RESULT (one line) and BCX_BODY (the fetch_* JSON,
#   else empty). Always returns 0: the outcome lives in the vars.
#
# THE ROW IS UNTRUSTED INPUT. Every check runs in here, not in the caller:
# the project must be an exact fleet.conf project (or `hub` for fetch_log and
# run_script), the payload must parse, a
# slug is [A-Za-z0-9_-]+ or refused (never stripped into a different slug),
# fetch_* paths go through the scripts' own --path whitelists, and empty map or
# chat text is refused before any script runs. The command id reaches a script
# only as one quoted argv element or a jq --arg.
#
# Synchronous calls are bounded by `timeout 30`, the bound the ssh forward put
# on the same calls, so a hung script cannot hold the lane's lock for ever.

# _bcx_detach <cmd> [args...] — launch and forget. fd 9 (the lane's lock) and
# fd 7 (poll-commands' poller.lock) are closed, so a minutes-long child never
# holds a lock the next tick needs.
_bcx_detach() { ( setsid "$@" </dev/null >/dev/null 2>&1 7>&- 9>&- & ); }

# _bcx_slug <payload> — print .slug when it is a plain slug, else nothing.
_bcx_slug() {
  local s
  s=$(jq -r '.slug // ""' <<<"$1" 2>/dev/null)
  case "$s" in ''|*[!A-Za-z0-9_-]*) return 1 ;; esac
  printf '%s' "$s"
}

bcx_run() {
  local type="${1:-}" project="${2:-}" payload="${3:-}" id="${4:-}"
  local h="${HARNESS:-/root/harness}" which key pproj out rc f slug b64 text origin
  BCX_OK=0; BCX_RESULT=""; BCX_BODY=""

  if ! { { [ "$type" = fetch_log ] || [ "$type" = run_script ]; } && [ "$project" = hub ]; } \
     && ! "$h/bin/fleet-conf.sh" --projects 2>/dev/null | grep -qxF -- "$project"; then
    BCX_RESULT="refused: '$project' is not a fleet.conf project"; return 0
  fi
  if ! printf '%s' "$payload" | jq -e . >/dev/null 2>&1; then
    BCX_RESULT="refused: payload is not JSON"; return 0
  fi

  case "$type" in
    run_triage)
      _bcx_detach "$h/bin/run-triage.sh" "$project"
      BCX_OK=1; BCX_RESULT="triage launched" ;;

    fetch_log|fetch_artifact)
      which=$(jq -r '.which // ""' <<<"$payload"); case "$which" in null) which="" ;; esac
      key=$(jq -r '.key // ""' <<<"$payload"); case "$key" in null) key="" ;; esac
      pproj=$(jq -r '.project // ""' <<<"$payload"); case "$pproj" in null) pproj="" ;; esac
      if [ -n "$pproj" ] && [ "$pproj" != "$project" ]; then
        BCX_RESULT="refused: payload project '$pproj' does not match row project '$project'"; return 0
      fi
      if [ "$type" = fetch_log ]; then
        timeout 30 "$h/bin/fetch-log.sh" --path "$which" "$project" >/dev/null 2>&1; rc=$?
        if [ "$rc" -ne 0 ]; then
          BCX_RESULT="refused: no whitelisted log for which='$which' project='$project'"
          BCX_BODY=$("$h/bin/fetch-log.sh" --error "$project" "$which" "$id" refused 2>/dev/null)
          return 0
        fi
        out=$(timeout 30 "$h/bin/fetch-log.sh" "$project" "$which" "$id" 2>/dev/null)
      else
        # rc 1 is a refusal; rc 2 is "nothing here yet", which is not one.
        timeout 30 "$h/bin/fetch-artifact.sh" --path "$project" "$key" "$which" >/dev/null 2>&1; rc=$?
        if [ "$rc" -eq 1 ]; then
          BCX_RESULT="refused: no whitelisted artifact for which='$which' key='$key' project='$project'"
          BCX_BODY=$("$h/bin/fetch-artifact.sh" --error "$project" "$key" "$which" "$id" refused 2>/dev/null)
          return 0
        fi
        out=$(timeout 30 "$h/bin/fetch-artifact.sh" "$project" "$key" "$which" "$id" 2>/dev/null)
      fi
      if [ -n "$out" ] && jq -e . >/dev/null 2>&1 <<<"$out"; then
        BCX_OK=1; BCX_BODY="$out"
        if [ "$type" = fetch_log ]; then BCX_RESULT="log tail read on this box"; else BCX_RESULT="artifact tail read on this box"; fi
      else
        BCX_RESULT="fetch failed"
        if [ "$type" = fetch_log ]; then
          BCX_BODY=$("$h/bin/fetch-log.sh" --error "$project" "$which" "$id" fetch_failed 2>/dev/null)
        else
          BCX_BODY=$("$h/bin/fetch-artifact.sh" --error "$project" "$key" "$which" "$id" fetch_failed 2>/dev/null)
        fi
      fi ;;

    chat)
      # The orchestrator inbox is the hub's; it stays in bin/poll-commands.sh.
      case "$project" in ''|null|orchestrator)
        BCX_RESULT="refused: orchestrator chat runs on the hub, not a box"; return 0 ;; esac
      text=$(jq -r '.text // ""' <<<"$payload"); case "$text" in null) text="" ;; esac
      [ -n "$text" ] || { BCX_RESULT="refused: empty chat text"; return 0; }
      origin=$(jq -r '.origin // ""' <<<"$payload"); case "$origin" in null) origin="" ;; esac
      b64=$(jq -nc --arg t "$text" --arg id "$id" --arg o "${origin:-dash}" --arg p "$project" \
        '{text:$t,command_id:$id,origin:$o,project:$p}' | base64 -w0)
      _bcx_detach "$h/bin/box-chat.sh" --b64 "$b64" "$id"
      BCX_OK=1; BCX_RESULT="chat handed to the $project box session" ;;

    update_company_map)
      # Map text rides a temp FILE (128KB argv-limit lesson), removed on every
      # path out of this arm.
      f=$(mktemp -t map-inbound-XXXXXX.md) || { BCX_RESULT="map update failed: mktemp"; return 0; }
      # -j, not -r: -r ends the text with a newline, so an empty map would not
      # be an empty file and would reach product-cmd.
      jq -j '.content // ""' <<<"$payload" > "$f"
      if [ ! -s "$f" ]; then
        BCX_RESULT="refused: empty map content"
      elif out=$(timeout 30 "$h/bin/product-cmd.sh" "$project" update_company_map map "$f" 2>&1); then
        BCX_OK=1; BCX_RESULT=$(head -c 200 <<<"$out")
      else
        BCX_RESULT="map update failed: $(head -c 200 <<<"$out")"
      fi
      rm -f "$f" ;;

    chat_proposal)
      slug=$(_bcx_slug "$payload") || { BCX_RESULT="refused: missing or invalid slug"; return 0; }
      b64=$(jq -c '{message: (.message // ""), origin: (.origin // "dash")}' <<<"$payload" | base64 -w0)
      ( setsid "$h/bin/product-cmd.sh" "$project" chat_proposal "$slug" "$b64" \
          </dev/null >>"$h/logs/$project.log" 2>&1 7>&- 9>&- & )
      BCX_OK=1; BCX_RESULT="chat launched" ;;

    post_proposal|kill_proposal|revise_proposal)
      slug=$(_bcx_slug "$payload") || { BCX_RESULT="refused: missing or invalid slug"; return 0; }
      b64=$(jq -r '.notes // ""' <<<"$payload" | base64 -w0)
      if out=$(timeout 30 "$h/bin/product-cmd.sh" "$project" "$type" "$slug" "$b64" 2>&1); then
        BCX_OK=1; BCX_RESULT=$(head -c 300 <<<"$out")
      else
        BCX_RESULT="product-cmd failed: $(head -c 300 <<<"$out")"
      fi ;;

    run_script)
      # bin/cmd-run-script.sh does every check (allowlist, argv-only args) and
      # bounds the script at 300 s; 330 here covers its own work around it.
      out=$(timeout 330 "$h/bin/cmd-run-script.sh" "$project" "$payload" "$id" 7>&- 9>&- 2>/dev/null); rc=$?
      [ "$rc" = 0 ] && BCX_OK=1
      BCX_RESULT="$out"
      [ -n "$BCX_RESULT" ] || BCX_RESULT=$(jq -nc --arg r "cmd-run-script.sh gave no result (rc $rc)" '{result:"failed",reason:$r}') ;;

    *)
      BCX_RESULT="refused: $type does not run on a box" ;;
  esac
  # One line: a multi-line script answer must not split the row's result.
  BCX_RESULT=$(printf '%s' "$BCX_RESULT" | tr '\n' ' ')
  return 0
}
