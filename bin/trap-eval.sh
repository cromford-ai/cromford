#!/bin/bash
# bin/trap-eval.sh --model <id>[@<runner>] [--model ...] [--trap N] [--scenario name]
#                  [--dry-run] [--list]
#
# TRAP EVALS (BH-128). Runs each selected trap scenario against each --model and
# grades the session with the scenario's hidden judge.sh. Cells run one at a
# time; every cell is one metered agent-call.sh call on stage `trapeval`.
#
# No model is defaulted: at least one --model is required. A --model with no
# @runner runs on claude, the one runner with a verified no-tools flag.
# Contract: catalog/fixtures/trap-evals/README.md.
#
# Exit: 0 = graded (null verdicts allowed), or the lane is switched off
#       (flags/all-off, flags/lane-off-trap-eval); 2 = could not run,
#       3 = a session wrote outside its sandbox.
set -u
EVAL_STAGE="trapeval"   # agent-call.sh stage + lane in catalog/context-budgets.json
# Names the registry lane (catalog/lanes.d/trap-eval.json) whose LLM knobs llm-gate.sh reads.
export AGENT_CALL_LANE=trap-eval
SELF=$(cd "$(dirname "$0")" && pwd)
HARNESS="${HARNESS:-/root/harness}"
# The box's real env dir, read once here: every cell runs with HARNESS_ENV_DIR at
# an empty scratch dir, and only the runner accounts under this one stay visible.
. "$SELF/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-$HARNESS}/env"; }
HENV_REAL=$(harness_env_dir "$HARNESS")
# shellcheck source=bin/lib/trap-eval-cells.sh
. "$SELF/lib/trap-eval-cells.sh" || exit 2
# shellcheck source=bin/lib/hub-box.sh
. "$SELF/lib/hub-box.sh" || exit 2

usage() { sed -n '2,3p' "$0" >&2; exit 2; }
die() { echo "trap-eval: $*" >&2; exit 2; }

MODELS=(); TRAP=""; ONE=""; DRY=0; LIST=0
while [ $# -gt 0 ]; do
  case "$1" in
    --model)    [ $# -ge 2 ] || die "--model needs a value"; MODELS+=("$2"); shift 2 ;;
    --trap)     [ $# -ge 2 ] || die "--trap needs a value"; TRAP="$2"; shift 2 ;;
    --scenario) [ $# -ge 2 ] || die "--scenario needs a value"; ONE="$2"; shift 2 ;;
    --dry-run)  DRY=1; shift ;;
    --list)     LIST=1; shift ;;
    -h|--help)  usage ;;
    *)          die "unknown argument: $1" ;;
  esac
done
case "$TRAP" in ""|[1-4]) ;; *) die "--trap must be 1-4, got '$TRAP'" ;; esac
[ "$LIST" = 1 ] || [ ${#MODELS[@]} -gt 0 ] || die "--model is required (no model is defaulted)"
for m in "${MODELS[@]}"; do
  case "$m" in ""|@*|*@) die "--model '$m' has no model id or runner" ;; esac
done

# The lane gate: flags/all-off or flags/lane-off-trap-eval exits 0 here, before
# any cell. The lib beside this script is the fallback, like every other lib here.
. "$HARNESS/bin/lib/lane-gate.sh" 2>/dev/null || . "$SELF/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit trap-eval
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    trap-eval

# ---- refusal 1: jq
command -v jq >/dev/null 2>&1 || die "jq is required (scenario metadata is JSON)"

# ---- refusal 2: fixtures. Same resolution as prompt-eval.sh: the deployed
# harness, then the checkout, then this script's own tree.
pick_dir() { for d in "$@"; do [ -n "$d" ] && [ -d "$d" ] && { printf '%s' "$d"; return 0; }; done; return 1; }
FIX=$(pick_dir "${TRAP_EVAL_FIXTURES:-}" "$HARNESS/catalog/fixtures/trap-evals" \
               /root/harness-checkout/catalog/fixtures/trap-evals "$SELF/../catalog/fixtures/trap-evals") \
  || die "no trap-eval scenarios: no fixture root found (set TRAP_EVAL_FIXTURES)"
ALL=0; SEL=()
for meta in "$FIX"/trap*/*/meta.json; do
  [ -f "$meta" ] || continue
  ALL=$((ALL+1))
  d=$(dirname "$meta")
  t=$(jq -r '.trap // empty' "$meta" 2>/dev/null)
  n=$(jq -r '.name // empty' "$meta" 2>/dev/null)
  [ -z "$TRAP" ] || [ "$t" = "$TRAP" ] || continue
  [ -z "$ONE" ] || [ "$n" = "$ONE" ] || [ "$(basename "$d")" = "$ONE" ] || continue
  SEL+=("$d")
done
[ ${#SEL[@]} -gt 0 ] || die "no trap-eval scenarios selected under $FIX (trap='${TRAP:-any}' scenario='${ONE:-any}')"

meta_get() { jq -r "$2" "$1/meta.json" 2>/dev/null; }
tools_of() { [ "$(meta_get "$1" '.tools == true')" = true ] && echo true || echo false; }
scen_of() { local n; n=$(meta_get "$1" '.name // empty'); printf '%s' "${n:-$(basename "$1")}"; }

if [ "$LIST" = 1 ]; then
  for d in "${SEL[@]}"; do
    printf 'trap%s  %s  tools=%s\n' "$(meta_get "$d" .trap)" "$(scen_of "$d")" "$(tools_of "$d")"
  done
  exit 0
fi

# ---- refusal 3: the hub never runs a tools scenario
if is_hub_box "$(local_box_name)"; then
  for d in "${SEL[@]}"; do
    [ "$(tools_of "$d")" = true ] && die "refusing on the hub: $(scen_of "$d") is a tools scenario (select --trap 2 or run on a worker box)"
  done
fi

# ---- refusal 4: the credential scrub comes from prompt-eval.sh's grade block,
# extracted rather than copied, so there is one list. No block, no run.
GRADE=$(mktemp "${TMPDIR:-/tmp}/trap-eval-grade.XXXXXX") || die "cannot create a temp file"
awk '/^# >>> prompt_eval_grade/{f=1;next} /^# <<< prompt_eval_grade/{exit} f' "$SELF/prompt-eval.sh" > "$GRADE" 2>/dev/null
# shellcheck disable=SC1090
{ [ -s "$GRADE" ] && . "$GRADE" && declare -F scrub_env_names >/dev/null; } \
  || { rm -f "$GRADE"; die "cannot extract scrub_env_names from $SELF/prompt-eval.sh; refusing to run unscrubbed"; }
rm -f "$GRADE"
SCRUB_NAMES=$(compgen -e | scrub_env_names | sort)
SCRUB=()
while IFS= read -r v; do [ -n "$v" ] && SCRUB+=(-u "$v"); done <<<"$SCRUB_NAMES"

# ---- the cells
CELLS=()   # "model|runner|scenario_dir"
for m in "${MODELS[@]}"; do
  model=${m%@*}; runner=claude
  [ "$model" = "$m" ] || runner=${m##*@}
  for d in "${SEL[@]}"; do CELLS+=("$model|$runner|$d"); done
done

if [ "$DRY" = 1 ]; then
  for c in "${CELLS[@]}"; do
    IFS='|' read -r model runner d <<<"$c"
    printf '%s@%s trap%s/%s tools=%s\n' "$model" "$runner" "$(meta_get "$d" .trap)" "$(scen_of "$d")" "$(tools_of "$d")"
  done
  # The first budgets file that actually declares the lane wins; none = unknown, never a guess.
  CEIL=""
  for f in "$HARNESS/catalog/context-budgets.json" /root/harness-checkout/catalog/context-budgets.json \
           "$SELF/../catalog/context-budgets.json"; do
    [ -f "$f" ] || continue
    CEIL=$(jq -r '[.lanes[] | select(.lane=="trap-eval") | .ceiling_tokens][0] // empty' "$f" 2>/dev/null)
    case "$CEIL" in ''|*[!0-9]*) CEIL="" ;; *) break ;; esac
  done
  if [ -n "$CEIL" ]; then
    echo "trap-eval: dry run: ${#CELLS[@]} cells × $CEIL ceiling tokens = $(( ${#CELLS[@]} * CEIL )) tokens worst case; 0 calls"
  else
    echo "trap-eval: dry run: ${#CELLS[@]} cells × ceiling unknown (no trap-eval lane in context-budgets.json); 0 calls"
  fi
  exit 0
fi

# ---- refusal 5: one run at a time; a held lock is a skip, never a wait
mkdir -p "$HARNESS/locks" || die "cannot create $HARNESS/locks"
exec 9>"$HARNESS/locks/trap-eval.lock" || die "cannot open $HARNESS/locks/trap-eval.lock"
flock -n 9 || die "another trap-eval run holds $HARNESS/locks/trap-eval.lock; skipping"

AGENT_CALL="${TRAP_EVAL_AGENT_CALL:-$SELF/agent-call.sh}"
TS=$(date -u +%Y%m%dT%H%M%SZ)
RUN="$HARNESS/state/trap-evals/$TS-$$"
mkdir -p "$RUN" || die "cannot create $RUN"
: > "$RUN/cells.jsonl"
VIOL=0; i=0

for c in "${CELLS[@]}"; do
  i=$((i+1))
  IFS='|' read -r model runner d <<<"$c"
  trap_n=$(meta_get "$d" .trap); scen=$(scen_of "$d"); tools=$(tools_of "$d")
  timeout_s=$(meta_get "$d" '.timeout_s // 900')
  cell="$RUN/$(printf '%s@%s--trap%s-%s' "$model" "$runner" "$trap_n" "$scen" | tr -c 'A-Za-z0-9._@-' _)"
  mkdir -p "$cell"
  tag="trapeval-$TS-$$-$i"
  OUT="$cell/out.txt"; PROMPT="$cell/prompt.md"
  printf '%s\n' "$SCRUB_NAMES" > "$cell/env-scrub.txt"
  verdict=""; reason=""; denied=0

  if ! [ -s "$d/ticket.md" ] || ! cp "$d/ticket.md" "$PROMPT"; then
    verdict=null; reason="scenario has no ticket.md"
  elif [ "$tools" = false ] && [ "$runner" != claude ]; then
    verdict=null; reason="runner cannot enforce no-tools"
  else
    S=$(mktemp -d "${TMPDIR:-/tmp}/trap-eval.XXXXXX") || die "cannot create a scratch root"
    mkdir "$S/gh"; : > "$S/gitconfig"
    # env(1) takes every -u before the first NAME=value.
    W="$S"; BASE=""; NT_UNSET=(-u AGENT_CALL_NO_TOOLS); NT_SET=()
    if [ "$tools" = true ]; then
      W="$S/wt"; mkdir "$W"
      [ -d "$d/repo" ] && cp -a "$d/repo/." "$W/"
      ( cd "$W" && export GIT_CONFIG_GLOBAL="$S/gitconfig" GIT_CONFIG_NOSYSTEM=1 \
        && git init -q && git config user.name trap-eval && git config user.email trap-eval@localhost \
        && git add -A && git commit -qm base --allow-empty \
        && git init --bare -q "$S/origin.git" && git remote add origin "$S/origin.git" ) >/dev/null 2>&1 \
        || { rm -rf "$S"; die "cannot build the sandbox repo for $scen"; }
      BASE=$(git -C "$W" rev-parse HEAD)
    else
      NT_UNSET=(); NT_SET=(AGENT_CALL_NO_TOOLS=1)
    fi
    # HARNESS_ENV_DIR at an EMPTY scratch dir (#2031 lead review): agent-call
    # sources bin/jobs-client.sh, which re-reads a scrubbed HARNESS_SECRET from
    # <env dir>/global.env and exports it, so the eval CLI inherited the jobs
    # worker's admin secret. With no global.env there is nothing to re-read.
    # ACCOUNTS_DIR keeps the runner accounts reachable (account-pick reads it
    # before the env dir); those tokens are runner credentials by design.
    mkdir "$S/env"
    ISO=(GH_CONFIG_DIR="$S/gh" GIT_CONFIG_GLOBAL="$S/gitconfig"
         HARNESS_ENV_DIR="$S/env" ACCOUNTS_DIR="${ACCOUNTS_DIR:-$HENV_REAL/accounts.d}")
    touch "$cell/.t0"
    : > "$OUT"
    ( cd "$W" && env "${SCRUB[@]}" "${NT_UNSET[@]}" "${ISO[@]}" \
        IRON_LAW_LANES="${IRON_LAW_LANES:-plan execute review fix qa triage} trapeval" \
        LADDER_TIER2_GROK=0 RUNNER_TRAPEVAL="$runner" RUNNER_TRAPEVAL_FALLBACK= \
        COST_KEY="$tag" HARNESS_TICKET="$tag" "${NT_SET[@]}" \
        "$AGENT_CALL" "$EVAL_STAGE" trap-eval "$model" "$timeout_s" "$OUT" "@$PROMPT" ) >/dev/null 2>&1

    denied=$(cat "$OUT" "$OUT.json" 2>/dev/null | grep -c 'BLOCKED by the harness act-time iron-law guard')
    echo "$denied" > "$cell/guard-denied.txt"
    cls=$(trap_eval_classify "$OUT" "$HARNESS/logs/cost.csv" "$tag" "$runner")
    oob=$(trap_eval_oob_scan "$cell/.t0" "$RUN")
    if [ -n "$oob" ]; then
      verdict=violation; reason="out-of-bounds write: $(head -1 <<<"$oob")"; VIOL=$((VIOL+1))
    elif [ "${cls%%:*}" = null ]; then
      verdict=null; reason="${cls#null:}"
    else
      # Before the judge: a judge that runs tests can dirty the tree. A throwaway
      # index picks up untracked files without touching the worktree's own.
      [ -n "$BASE" ] && ( cd "$W" && GIT_INDEX_FILE="$S/idx" git add -A \
        && GIT_INDEX_FILE="$S/idx" git diff --cached "$BASE" ) > "$cell/diff.patch" 2>/dev/null
      ( cd "$d" && env "${SCRUB[@]}" "${ISO[@]}" timeout "${TRAP_EVAL_JUDGE_TIMEOUT:-300}" \
          bash judge.sh "$W" "$OUT" "$BASE" ) > "$cell/judge.out" 2>&1
      jrc=$?
      verdict=$(trap_eval_verdict "$jrc")
      [ "$verdict" = null ] && reason="judge error rc=$jrc"
    fi
    case "$S" in */trap-eval.*) rm -rf "$S" ;; esac
  fi

  jq -nc --arg model "$model" --arg runner "$runner" --arg trap "$trap_n" --arg scenario "$scen" \
    --arg verdict "$verdict" --arg reason "$reason" --argjson denied "${denied:-0}" --arg cell_dir "$cell" \
    '{model:$model, runner:$runner, trap:($trap|tonumber? // null), scenario:$scenario,
      verdict:$verdict, reason:$reason,
      cost_usd:null, guard_denied:($denied > 0), cell_dir:$cell_dir}' >> "$RUN/cells.jsonl"
done

NOTE=""
[ ${#SEL[@]} -lt "$ALL" ] && NOTE="partial run: ${#SEL[@]} of $ALL scenarios" && echo "trap-eval: $NOTE"
trap_eval_report "$RUN/cells.jsonl" "$HARNESS/state/trap-evals.json" "$RUN/result.json" "$NOTE"
rrc=$?
if [ "$VIOL" -gt 0 ]; then
  mkdir -p "$HARNESS/logs"
  echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') trap-eval: $VIOL out-of-bounds write(s) in $RUN — read the violation cells in $RUN/cells.jsonl" >> "$HARNESS/logs/ALERTS.log"
  exit 3
fi
[ "$rrc" -eq 0 ] || exit 2
exit 0
