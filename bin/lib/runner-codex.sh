#!/bin/bash
# bin/lib/runner-codex.sh — run one stage prompt file on the codex lane of
# bin/agent-call.sh (BH-7967, parent BH-7937 decision 6).
#
# Usage: bin/lib/runner-codex.sh <prompt-file> <stage> <project> <timeout-sec> <outfile>
#
# <prompt-file> is the file a claude call gives agent-call as @<path>; the other
# four are agent-call's arguments of the same name. The stage prompt text is not
# changed: agent-call reads the file, and the codex lane gets it on stdin.
#
# rc: agent-call's rc; 2 = usage or unreadable prompt file; 75 = no codex.default
# route. On rc 2 and 75 nothing is called.

usage() { echo "usage: $(basename "$0") <prompt-file> <stage> <project> <timeout-sec> <outfile>" >&2; exit 2; }
[ "$#" -eq 5 ] || usage
FILE="$1"; STAGE="$2"; PROJECT="$3"; TO="$4"; OUT="$5"
for a in "$FILE" "$STAGE" "$PROJECT" "$TO" "$OUT"; do [ -n "$a" ] || usage; done
[ -f "$FILE" ] && [ -r "$FILE" ] || { echo "runner-codex: prompt file not readable: $FILE" >&2; exit 2; }
# agent-call reads only an absolute @/path.
FILE="$(cd "$(dirname "$FILE")" && pwd)/$(basename "$FILE")"

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
# The model, in agent-call's codex_model order: the operator's env override,
# then the codex.default model_routes row. No literal: no route is rc 75.
MODEL="${CODEX_MODEL:-${CODEX_DEFAULT_MODEL:-}}"
if [ -z "$MODEL" ]; then
  # shellcheck source=bin/lib/model-route.sh
  . "$SELF_DIR/model-route.sh" || { echo "runner-codex: cannot load $SELF_DIR/model-route.sh" >&2; exit 75; }
  MODEL=$(model_for codex.default "$PROJECT") && [ -n "$MODEL" ] \
    || { echo "runner-codex: no model route for role codex.default (project=$PROJECT); nothing was called" >&2; exit 75; }
fi

# The documented operator override, folded the way agent-call folds the stage.
# It keeps RUNNER_<STAGE>_FALLBACK and the claude fallback.
SU=$(printf '%s' "$STAGE" | tr '[:lower:]' '[:upper:]' | tr -c '[:alnum:]_' '_')
export "RUNNER_$SU=codex"
# AGENT_ARGV_MAX=0 is a transport mode, not a limit: every prompt is "too big"
# for argv, so the codex lane always runs `codex exec ... -` with the prompt on
# stdin. Set for this child only; other callers keep the box default.
# agent-call-tools: a build stage (plan, execute, fix) runs on codex and needs tools
exec env AGENT_ARGV_MAX=0 "$SELF_DIR/../agent-call.sh" "$STAGE" "$PROJECT" "$MODEL" "$TO" "$OUT" "@$FILE"
