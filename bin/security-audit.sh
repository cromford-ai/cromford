#!/bin/bash
# bin/security-audit.sh — one capped whole-repo security audit of a project with
# the cloudflare/security-audit-skill (BH-7910). Operator-invoked: no cron line;
# lane security-audit (catalog/lanes.d/security-audit.json) holds its switch and
# knobs. The result is an artifact directory, never a commit and never a ticket.
#
# usage: security-audit.sh <project> [--out <dir>] [--cap-usd <n>] [--cap-minutes <n>] [--again]
#   --out          the artifact root (default $BUILD/security-audit when BUILD is
#                  set, else $HARNESS/state/security-audit); a run writes
#                  <out>/<project>/run-<N>/ and <out>/<project>/latest-summary.json
#   --cap-usd      dollar cap (default: settings row security_audit.cap_usd, else
#                  cap_usd in catalog/security-audit.conf)
#   --cap-minutes  wall-clock cap (default: settings row security_audit.cap_minutes,
#                  else cap_minutes in the conf)
#   --again        run even when a completed run of the same target sha and skill
#                  sha exists (the dedup before spend)
#
# What one run does, in this order:
#   1. clones the target's main into <out>/<project>/.scratch-<pid> (never the
#      live checkout); the url is SA_REPO_URL, else the live checkout's origin
#      url, else https://github.com/<fleet.conf slug>
#   2. dedup: prints `SKIP already-audited <summary>` and exits 0 with no call
#      when a run-*/summary.json has the same sha, skill_sha, stopped=completed
#   3. clones the skill repo, checks out skill_sha and refuses (rc 3) when HEAD
#      is not skill_sha, naming the sha it found
#   4. removes .claude/, .mcp.json, CLAUDE.md, CLAUDE.local.md from the clone
#      (neutralized.txt), then `npx skills@<pin> add <verified clone>` into it and
#      refuses (rc 4) when the installed SKILL.md differs from the verified one
#   5. picks the sandbox (bin/security-audit-sandbox.sh --detect, sandbox.txt)
#   6. runs bin/agent-call.sh stage `audit` (model: route stage.audit) with
#      AGENT_CALL_BUDGET_USD_AUDIT=<cap-usd>, cwd = the clone, and polls every
#      poll_s: elapsed >= cap-minutes or cost >= cap-usd stops the session
#      (TERM, KILL after kill_grace_s); a stopped run keeps the files already
#      written. agent-call's own timeout is cap-minutes plus
#      agent_timeout_margin_s. A session that ends rc 0 with no `AUDIT DONE`
#      line in its output is stopped=incomplete, which dedup does not count
#   7. runs the skill's validate-findings.cjs and validate-coverage-ledger.cjs
#      and writes summary.json; the clones are removed on exit
# Exit: 0 completed, capped, incomplete, dedup skip or already running; 2 usage or bad cap; 3 pin refused;
#       4 clone or install failed; 5 the agent call failed.
# Test seams: SA_REPO_URL, SA_CONF, SA_MINUTE_S (seconds per cap minute, 60),
# SA_POLL_S, SA_KILL_GRACE_S, SA_AGENT_CALL. The default path is the real
# bin/agent-call.sh.
set -uo pipefail

SELF="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$SELF")"
H="${HARNESS:-/root/harness}"
export HARNESS="$H"
# LANE security-audit: the switch and the knobs, before anything is cloned or
# bought. No lane-gate.sh under $HARNESS (a Mac, a test tree) fails open.
. "$HARNESS/bin/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit security-audit
command -v lane_env_apply >/dev/null 2>&1 && lane_env_apply security-audit

usage() { sed -n '/^# usage:/,/^# bin\/agent-call.sh\.$/p' "$0" | sed 's/^# \{0,1\}//'; }

# shellcheck source=bin/lib/security-audit.sh
. "$SELF/lib/security-audit.sh" || { echo "security-audit: cannot load bin/lib/security-audit.sh" >&2; exit 2; }

PROJECT="" OUT="" F_USD="" F_MIN="" AGAIN=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --out) OUT="${2:-}"; shift 2 || { usage >&2; exit 2; } ;;
    --cap-usd) F_USD="${2:-}"; shift 2 || { usage >&2; exit 2; } ;;
    --cap-minutes) F_MIN="${2:-}"; shift 2 || { usage >&2; exit 2; } ;;
    --again) AGAIN=1; shift ;;
    -*) echo "security-audit: unknown flag $1" >&2; usage >&2; exit 2 ;;
    *) [ -z "$PROJECT" ] || { usage >&2; exit 2; }; PROJECT="$1"; shift ;;
  esac
done
case "$PROJECT" in ''|*[!a-z0-9._-]*) usage >&2; exit 2 ;; esac
[ -n "$OUT" ] || OUT="${BUILD:+$BUILD/security-audit}"
OUT="${OUT:-$H/state/security-audit}"

CONF="${SA_CONF:-$REPO/catalog/security-audit.conf}"
[ -r "$CONF" ] || { echo "security-audit: no conf $CONF" >&2; exit 2; }
for k in skill_repo skill_sha skill_path skill_name skills_cli_version; do
  sa_conf_get "$CONF" "$k" >/dev/null || { echo "security-audit: $CONF has no $k" >&2; exit 2; }
done
SKILL_REPO=$(sa_conf_get "$CONF" skill_repo); SKILL_SHA=$(sa_conf_get "$CONF" skill_sha)
SKILL_PATH=$(sa_conf_get "$CONF" skill_path); SKILL_NAME=$(sa_conf_get "$CONF" skill_name)
CLI_VER=$(sa_conf_get "$CONF" skills_cli_version)
# Each literal below is only the documented fallback of the conf key it names.
POLL_S="${SA_POLL_S:-$(sa_conf_get "$CONF" poll_s || echo 30)}"
MINUTE_S="${SA_MINUTE_S:-60}"
GRACE_S="${SA_KILL_GRACE_S:-$(sa_conf_get "$CONF" kill_grace_s || echo 30)}"
MARGIN_S=$(sa_conf_get "$CONF" agent_timeout_margin_s || echo 300)

# The settings rows win over the conf; the client is fail-open (no worker = conf).
# shellcheck source=bin/jobs-client.sh
. "$SELF/jobs-client.sh" >/dev/null 2>&1 || true
set -uo pipefail
CAPS=$(sa_caps "$F_USD" "$F_MIN" "$CONF") || exit 2
read -r CAP_USD CAP_MIN _ _ <<<"$CAPS"

PD="$OUT/$PROJECT"
mkdir -p "$PD" || { echo "security-audit: cannot create $PD" >&2; exit 2; }
PD=$(cd "$PD" && pwd -P)  # physical: the CLI keys transcripts on its real cwd
LOG="$H/logs/security-audit.log"
mkdir -p "$H/logs" 2>/dev/null
# One run per project at a time, so two runs started together cannot both pass
# dedup and both pay. The lock lives as long as this process.
exec 9>"$OUT/.$PROJECT.lock"
if ! flock -n 9; then
  echo "SKIP already-running $PROJECT"
  echo "$(date -u +%FT%TZ) $PROJECT skip already-running" >> "$LOG" 2>/dev/null
  exit 0
fi
SCRATCH="$PD/.scratch-$$"
SKILL_DIR="$PD/.skill-$$"
CHILD=""
# sig_session <signal> — every process of the session's own sid. A process
# group is not enough: GNU timeout (inside agent-call.sh) moves itself and the
# claude child into a new process group, but never out of the session.
sig_session() {
  pkill "-$1" -s "$CHILD" 2>/dev/null
  kill "-$1" -- "-$CHILD" 2>/dev/null || kill "-$1" "$CHILD" 2>/dev/null
  return 0
}
cleanup() {
  [ -n "$CHILD" ] && sig_session KILL
  rm -rf "$SCRATCH" "$SKILL_DIR"
}
trap cleanup EXIT

START=$(date -u +%s)
STARTED=$(date -u -d "@$START" +%FT%TZ)
RUN="" RUN_N="" SHA="" SANDBOX="" STOPPED="" FAILED="" AGENT_RC="null"
COST="null" COST_SRC="none" V_FIND="null" V_LEDGER="null"
COUNTS='{"confirmed":null,"needs_validation":null,"rejected":null,"note":"no audit ran"}'

new_run() { # claim the lowest free run-N, atomically
  local n
  while :; do
    n=$(sa_next_run "$OUT" "$PROJECT")
    mkdir "$PD/run-$n" 2>/dev/null && break
  done
  RUN_N="$n"; RUN="$PD/run-$n"
}

finish() { # finish <rc> — write summary.json, the latest copy and the log line
  local rc="$1" end ended dur json
  [ -n "$RUN" ] || new_run
  end=$(date -u +%s); ended=$(date -u -d "@$end" +%FT%TZ)
  dur=$(awk -v a="$START" -v b="$end" 'BEGIN{printf "%.2f", (b-a)/60}')
  json=$(jq -n --arg project "$PROJECT" --argjson run "$RUN_N" --arg sha "$SHA" --arg skill_sha "$SKILL_SHA" \
    --arg started "$STARTED" --arg ended "$ended" --argjson duration_min "$dur" \
    --argjson cost_usd "$COST" --arg cost_source "$COST_SRC" --arg stopped "$STOPPED" --arg failed_reason "$FAILED" \
    --arg sandbox "$SANDBOX" --argjson counts "$COUNTS" --argjson vf "$V_FIND" --argjson vl "$V_LEDGER" \
    --argjson agent_rc "$AGENT_RC" --arg cap_usd "$CAP_USD" --arg cap_minutes "$CAP_MIN" \
    '{project:$project, run:$run, sha:(if $sha == "" then null else $sha end), skill_sha:$skill_sha,
      started:$started, ended:$ended, duration_min:$duration_min, cost_usd:$cost_usd, cost_source:$cost_source,
      stopped:$stopped, failed_reason:(if $failed_reason == "" then null else $failed_reason end),
      sandbox:(if $sandbox == "" then null else $sandbox end),
      counts:{confirmed:$counts.confirmed, needs_validation:$counts.needs_validation, rejected:$counts.rejected},
      counts_note:$counts.note, validators:{findings:$vf, ledger:$vl}, agent_rc:$agent_rc,
      caps:{usd:($cap_usd | tonumber), minutes:($cap_minutes | tonumber)}}')
  sa_summary_write "$RUN/summary.json" "$json" && cp -f "$RUN/summary.json" "$PD/latest-summary.json"
  echo "$ended $PROJECT run-$RUN_N sha=${SHA:0:12} stopped=$STOPPED${FAILED:+ ($FAILED)} cost=$COST/$COST_SRC rc=$rc" >> "$LOG" 2>/dev/null
  echo "security-audit: $PROJECT run-$RUN_N stopped=$STOPPED cost_usd=$COST summary=$RUN/summary.json"
  exit "$rc"
}

fail() { STOPPED=failed; FAILED="$2"; echo "security-audit: $2" >&2; finish "$1"; }

# ── 1. the target, cloned fresh ──────────────────────────────────────────────
URL="${SA_REPO_URL:-}"
[ -n "$URL" ] || URL=$(git -C "${SA_REPOS_DIR:-/root/repos}/$PROJECT" remote get-url origin 2>/dev/null)
if [ -z "$URL" ]; then
  slug=$("$SELF/fleet-conf.sh" "$PROJECT" repo 2>/dev/null)
  [ -n "$slug" ] && URL="https://github.com/$slug"
fi
[ -n "$URL" ] || fail 4 "no repo url for $PROJECT (SA_REPO_URL, the live checkout, fleet.conf)"
git clone -q --depth 1 --branch main --no-tags "$URL" "$SCRATCH" >/dev/null 2>&1 \
  || fail 4 "clone of $PROJECT main failed"
SHA=$(git -C "$SCRATCH" rev-parse HEAD 2>/dev/null) || fail 4 "no HEAD in the clone of $PROJECT"

# ── 2. dedup before spend ────────────────────────────────────────────────────
if [ "$AGAIN" != 1 ] && HIT=$(sa_dedup_hit "$OUT" "$PROJECT" "$SHA" "$SKILL_SHA"); then
  echo "SKIP already-audited $HIT"
  echo "$(date -u +%FT%TZ) $PROJECT skip sha=${SHA:0:12} already-audited $HIT" >> "$LOG" 2>/dev/null
  exit 0
fi
new_run

# ── 3. the skill, pinned ─────────────────────────────────────────────────────
[[ "$SKILL_SHA" =~ ^[0-9a-f]{40}$ ]] || fail 3 "skill_sha '$SKILL_SHA' in $CONF is not a 40-hex sha"
git clone -q --no-tags "$SKILL_REPO" "$SKILL_DIR" >/dev/null 2>&1 || fail 4 "clone of $SKILL_REPO failed"
git -C "$SKILL_DIR" -c advice.detachedHead=false checkout -q --detach "$SKILL_SHA" >/dev/null 2>&1
FOUND=$(git -C "$SKILL_DIR" rev-parse HEAD 2>/dev/null)
[ "$FOUND" = "$SKILL_SHA" ] || fail 3 "pin refused: $SKILL_REPO pin $SKILL_SHA, found ${FOUND:-no sha}"
[ -f "$SKILL_DIR/$SKILL_PATH/SKILL.md" ] || fail 4 "no $SKILL_PATH/SKILL.md at $SKILL_SHA"

# ── 4. neutralize the target, then install the skill into it ────────────────
: > "$RUN/neutralized.txt"
while IFS= read -r -d '' p; do
  printf '%s\n' "${p#"$SCRATCH"/}" >> "$RUN/neutralized.txt"
  rm -rf "$p"
done < <(find "$SCRATCH" -path "$SCRATCH/.git" -prune -o \
           \( -name .claude -o -name .mcp.json -o -name CLAUDE.md -o -name CLAUDE.local.md \) -print0 -prune)
( cd "$SCRATCH" && DISABLE_TELEMETRY=1 DO_NOT_TRACK=1 \
    npx -y "skills@$CLI_VER" add "$SKILL_DIR" --skill "$SKILL_NAME" -a claude-code -y --copy ) > "$RUN/install.log" 2>&1 \
  || fail 4 "npx skills@$CLI_VER add failed (install.log)"
cmp -s "$SKILL_DIR/$SKILL_PATH/SKILL.md" "$SCRATCH/.claude/skills/$SKILL_NAME/SKILL.md" \
  || fail 4 "the installed SKILL.md differs from the verified clone at $SKILL_SHA"

# ── 5. the sandbox ───────────────────────────────────────────────────────────
SANDBOX=$("$SELF/security-audit-sandbox.sh" --detect)
CONTROLS=$("$SELF/security-audit-sandbox.sh" --describe "$SANDBOX")
printf '%s\n' "$CONTROLS" > "$RUN/sandbox.txt"
if [ "$SANDBOX" = none ]; then
  HOW="There is no sandbox command. Run nothing from the target."
else
  HOW="Run every target command through: $SELF/security-audit-sandbox.sh $SANDBOX $SCRATCH -- <command> [args...]"
fi

# ── 6. the session, capped ───────────────────────────────────────────────────
# shellcheck source=bin/lib/lane-model.sh
. "$SELF/lib/lane-model.sh" || fail 5 "cannot load bin/lib/lane-model.sh"
MODEL=$(lane_role_model stage.audit "$PROJECT") && [ -n "$MODEL" ] || fail 5 "no model route stage.audit"
shopt -u patsub_replacement 2>/dev/null
TPL=$(cat "$REPO/prompts/security-audit.md") || fail 5 "no prompts/security-audit.md"
TPL="${TPL//\{\{PROJECT\}\}/$PROJECT}"; TPL="${TPL//\{\{SHA\}\}/$SHA}"
TPL="${TPL//\{\{SKILL_SHA\}\}/$SKILL_SHA}"; TPL="${TPL//\{\{SKILL_NAME\}\}/$SKILL_NAME}"
TPL="${TPL//\{\{SCRATCH\}\}/$SCRATCH}"; TPL="${TPL//\{\{RUN_DIR\}\}/$RUN}"
TPL="${TPL//\{\{SANDBOX_MODE\}\}/$SANDBOX}"; TPL="${TPL//\{\{SANDBOX_CONTROLS\}\}/$CONTROLS}"
TPL="${TPL//\{\{SANDBOX_HOW\}\}/$HOW}"
printf '%s\n' "$TPL" > "$RUN/prompt.md"

AC="${SA_AGENT_CALL:-$SELF/agent-call.sh}"
CAP_S=$(awk -v m="$CAP_MIN" -v s="$MINUTE_S" 'BEGIN{printf "%d", m*s}')
# The live meter's transcript dirs, re-listed on each read: the session may run
# under an account's own CLAUDE_CONFIG_DIR, and a cut slug is a glob.
# shellcheck source=bin/lib/env-path.sh
. "$SELF/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "$H/env"; }
ENVD=$(harness_env_dir "$H")
cost_now() { sa_cost_usd "$H/logs/cost.csv" "$PROJECT" "$HOST" "$START" "$(sa_transcript_dirs "$SCRATCH" "$ENVD")"; }
HOST=$(hostname)
# Not a group leader (no job control here), so setsid does not fork: $! is the
# session leader, and its pid is the session id the caps stop.
( cd "$SCRATCH" && AGENT_CALL_BUDGET_USD_AUDIT="$CAP_USD" AGENT_CALL_LANE=security-audit \
    exec setsid "$AC" audit "$PROJECT" "$MODEL" "$((CAP_S + MARGIN_S))" "$RUN/agent-out.txt" "@$RUN/prompt.md" ) \
  > "$RUN/agent-call.log" 2>&1 9>&- &
CHILD=$!
stop_child() {
  local i=0
  sig_session TERM
  while pgrep -s "$CHILD" >/dev/null 2>&1 && [ "$i" -lt "$GRACE_S" ]; do sleep 1; i=$((i + 1)); done
  pgrep -s "$CHILD" >/dev/null 2>&1 && sig_session KILL
  return 0
}
CAPPED=""
while kill -0 "$CHILD" 2>/dev/null; do
  sleep "$POLL_S"
  kill -0 "$CHILD" 2>/dev/null || break
  if [ $(( $(date -u +%s) - START )) -ge "$CAP_S" ]; then CAPPED=cap-minutes; stop_child; break; fi
  read -r COST COST_SRC <<<"$(cost_now)"
  if [ "$COST" != null ] && awk -v c="$COST" -v k="$CAP_USD" 'BEGIN{exit !(c >= k)}'; then
    CAPPED=cap-usd; stop_child; break
  fi
done
wait "$CHILD" 2>/dev/null; AGENT_RC=$?
CHILD=""
read -r COST COST_SRC <<<"$(cost_now)"

# ── 7. validators, counts, summary ───────────────────────────────────────────
run_validator() { # run_validator <script-name> <file> <log> — the true rc, or null
  local v
  [ -f "$2" ] || { echo null; return; }
  v=$(find "$SKILL_DIR/$SKILL_PATH" -name "$1" -print -quit 2>/dev/null)
  [ -n "$v" ] || { echo "no $1 in $SKILL_PATH" > "$3"; echo null; return; }
  node "$v" "$2" > "$3" 2>&1
  echo $?
}
V_FIND=$(run_validator validate-findings.cjs "$RUN/findings.json" "$RUN/validate-findings.txt")
V_LEDGER=$(run_validator validate-coverage-ledger.cjs "$RUN/coverage-ledger.json" "$RUN/validate-coverage-ledger.txt")
COUNTS=$(sa_counts "$RUN/findings.json")

if [ -n "$CAPPED" ]; then
  STOPPED="$CAPPED"; finish 0
elif [ "$AGENT_RC" -ne 0 ]; then
  if [ "$AGENT_RC" -ge 74 ] && [ "$AGENT_RC" -le 79 ]; then
    fail 5 "agent-call refused (rc $AGENT_RC, nothing billed): $(head -c 300 "$RUN/agent-out.txt" 2>/dev/null)"
  fi
  fail 5 "agent-call rc $AGENT_RC"
fi
# rc 0 is not proof the audit finished: a turn limit or a budget stop can end
# the session early. Only the prompt's own last line counts as completed.
if ! grep -q 'AUDIT DONE' "$RUN/agent-out.txt" 2>/dev/null; then
  STOPPED=incomplete; FAILED="agent-call rc 0 with no AUDIT DONE line"; finish 0
fi
STOPPED=completed
finish 0
