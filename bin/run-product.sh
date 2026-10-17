#!/bin/bash
# AI product team — weekly generative stage (v2, org-walking chain).
# Phases: 0 MAP (cached company map, monthly) -> 1 SIGNALS (evidence harvest)
#      -> 2 IDEATE (fan-out per department)   -> 3 SYNTH (merge/dedup/rank)
#      -> SELECT (deterministic; DERISK -> UNCLOG -> SCALE, then score)
#      -> PRD + MOCKUP per selected idea -> GATE (the operator approves before any post).
# Never builds, never comments on existing tickets. Posting happens only through
# bin/post-proposal.sh after an approve command (or the off-by-default
# flags/product-autonomy-<project>).
set -uo pipefail
# BH-2303: every model call this lane makes names the lane, so its cost rows
# carry lane_id and its LLM_* knobs (on/off, runners, daily cap) bind it alone.
export AGENT_CALL_LANE=run-product
PROJECT="${1:?usage: run-product.sh <project>}"
HARNESS="${HARNESS:-/root/harness}"
. "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$HARNESS")

# >>> lane gate (BH-1165) — one off-switch and one source of numbers for this
# lane. lane_gate_or_exit exits 0 when flags/all-off, flags/lane-off-run-product
# (or its project row) is set; lane_env_apply then puts this
# lane's settings rows into the environment its own ${KNOB:-default} reads use.
# Both fail OPEN: an unreachable worker leaves the lane exactly as it is today.
# Registry: catalog/lanes.json. Operator: bin/harness-ctl.sh off run-product <project>.
# shellcheck disable=SC1091
. "${HARNESS:-/root/harness}/bin/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit run-product "$PROJECT"
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    run-product "$PROJECT"
REPO="/root/repos/$PROJECT"
LOG="$HARNESS/logs/$PROJECT.log"
ALERTS="$HARNESS/logs/ALERTS.log"
CTX_FILE="$HARNESS/prompts/product-$PROJECT.md"
STAGES="$HARNESS/prompts/product-stages"
LEDGER="$HARNESS/state/product-$PROJECT.ledger.json"
MAP="$HARNESS/state/$PROJECT.company-map.md"
CATALOG="$HARNESS/catalog/feature-catalog.md"
STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }

mkdir -p "$HARNESS/logs" "$HARNESS/locks" "$HARNESS/state" "$HARNESS/products"

set -a
[ -f "$HENV/global.env" ] && . "$HENV/global.env"
[ -f "$HENV/$PROJECT.env" ] && . "$HENV/$PROJECT.env"
set +a
# AND AGAIN, BELOW THE ENV LOAD (BH-1165 review). `set -a; . env/global.env`
# re-assigns every name it carries, so the call above lost each knob the box's
# env file also sets — the settings row was gone, the page went on reporting
# `source: settings`, and nothing errored: the exact shape this ticket exists to
# end. The call above still earns its place: the knobs this lane reads BEFORE
# this line have no other way to see a row. Applying twice is idempotent (the
# settings cache is already warm) and section 16 of tests/lanes-registry-test.sh
# is the ordering.
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    run-product "$PROJECT"

# >>> proposal rows (BH-2531): the ledger file is this box's working copy;
# harness-jobs product_proposals rows are the record that outlives it. Restored
# before the ledger is read, written through after each ledger write. Fail-open:
# no worker, or one that does not answer, leaves the file exactly as before.
# shellcheck source=bin/jobs-client.sh
[ -r "$HARNESS/bin/jobs-client.sh" ] && . "$HARNESS/bin/jobs-client.sh"
# shellcheck source=bin/lib/proposal-rows.sh
[ -r "$HARNESS/bin/lib/proposal-rows.sh" ] && . "$HARNESS/bin/lib/proposal-rows.sh"
command -v prow_put >/dev/null 2>&1 || { prow_put() { return 1; }; prow_restore() { return 1; }; }
# <<< proposal rows

# >>> PM agent seams (BH-7244): product_run_cap_check <stage> (owner BH-7244.5)
# and pm_ideas_land <project> <cycle_dir> (owner BH-7244.3). A missing file is
# fail-open: the cap never fires and nothing is landed, which is today.
# shellcheck source=bin/lib/product-run-cap.sh
[ -r "$HARNESS/bin/lib/product-run-cap.sh" ] && . "$HARNESS/bin/lib/product-run-cap.sh"
command -v product_run_cap_check >/dev/null 2>&1 || product_run_cap_check() { return 0; }
# shellcheck source=bin/lib/pm-ideas-land.sh
[ -r "$HARNESS/bin/lib/pm-ideas-land.sh" ] && . "$HARNESS/bin/lib/pm-ideas-land.sh"
command -v pm_ideas_land >/dev/null 2>&1 || pm_ideas_land() { return 0; }
DATA_EVIDENCE=0
cap_stop() { # cap_stop <stage> — a non-zero cap check ends the cycle with rc 0
  product_run_cap_check "$1" && return 0
  echo "$(STAMP) [$PROJECT] product rc=0 :: run cap reached after $1, cycle ended data_evidence=$DATA_EVIDENCE" >> "$LOG"
  exit 0
}
# <<< PM agent seams

# >>> gh default auth
# THE PROJECT'S OWN GITHUB IDENTITY (BH-470, #424). This lane makes no `gh` call
# itself — the Claude sessions it launches for each stage do, and they inherit
# this environment. So the consumer is every stage session below, and the point
# is the same as everywhere else in the fleet: one PAT is one 5000/h bucket for
# every box, an installation token is per-installation and dies in an hour.
# Both sources are fail-open and the call is guarded, so a box whose bin/lib/
# predates #469 forks nothing here and behaves exactly as it does today.
# shellcheck source=bin/lib/gh-app-auth.sh
[ -r "$HARNESS/bin/lib/gh-app-auth.sh" ] && . "$HARNESS/bin/lib/gh-app-auth.sh"
# shellcheck source=bin/lib/gh-limit-logger.sh
[ -r "$HARNESS/bin/lib/gh-limit-logger.sh" ] && . "$HARNESS/bin/lib/gh-limit-logger.sh"
if command -v gh_default_auth_for_project >/dev/null 2>&1; then
  gh_default_auth_for_project "$PROJECT" || true
fi
# <<< gh default auth

[ -f "$CTX_FILE" ] || { echo "$(STAMP) [$PROJECT] product: context prompt missing" >> "$ALERTS"; exit 1; }
[ -d "$STAGES" ] || { echo "$(STAMP) [$PROJECT] product: stage prompts missing" >> "$ALERTS"; exit 1; }
# BH-4153: the paused-<project> row through flag_active; the file only with no client.
if { command -v flag_active >/dev/null 2>&1 && flag_active "paused-$PROJECT" >/dev/null 2>&1; } \
   || { ! command -v flag_active >/dev/null 2>&1 && [ -f "$HARNESS/flags/paused-$PROJECT" ]; }; then
  echo "$(STAMP) [$PROJECT] product: board paused, skipping" >> "$LOG"; exit 0
fi
if [ -f "$HARNESS/flags/product-paused-$PROJECT" ]; then echo "$(STAMP) [$PROJECT] product: stage paused, skipping" >> "$LOG"; exit 0; fi

PLOCK="$HARNESS/locks/$PROJECT-product.lock"
exec 8>"$PLOCK"
flock -n 8 || { echo "$(STAMP) [$PROJECT] product: previous cycle still active, skipping" >> "$LOG"; exit 0; }

RUN_START_EPOCH=$(date +%s)
# A wiped box gets back every gated/posted/vetoed slug here, so the SELECT
# below skips them instead of drafting (and, with autonomy, posting) them again.
prow_restore "$PROJECT" "$LEDGER" || true
[ -f "$LEDGER" ] || echo '[]' > "$LEDGER"

# >>> model-route (BH-1510.2): one model_routes role per stage — product.map,
# product.signals, product.ideate, product.synth — each with its own env var
# still winning when set. The PRD and mockup stages are bin/draft-proposal.sh's
# (roles product.prd / product.mockup), resolved there. No route for any stage
# = rc 75 before the cycle spends anything, alerted by bin/lib/model-route.sh.
. "$HARNESS/bin/lib/lane-model.sh"
if ! { MAP_MODEL=$(lane_model MAP_MODEL product.map "$PROJECT") \
    && SIGNALS_MODEL=$(lane_model SIGNALS_MODEL product.signals "$PROJECT") \
    && IDEATE_MODEL=$(lane_model IDEATE_MODEL product.ideate "$PROJECT") \
    && SYNTH_MODEL=$(lane_model SYNTH_MODEL product.synth "$PROJECT"); }; then
  echo "$(STAMP) [$PROJECT] product: no model route for a product stage — cycle skipped" >> "$LOG"; exit 75
fi
# <<< model-route
PRODUCT_BATCH="${PRODUCT_BATCH:-3}"
PRODUCT_MIN_SCORE="${PRODUCT_MIN_SCORE:-10}"
MAP_MAX_AGE_DAYS="${MAP_MAX_AGE_DAYS:-30}"
IDEATE_CONCURRENCY="${IDEATE_CONCURRENCY:-3}"

CYCLE_DIR="$HARNESS/products/$PROJECT/$(date -u +%Y-%m-%d)"
mkdir -p "$CYCLE_DIR"

WORKDIR="$REPO"; [ -d "$REPO" ] || WORKDIR="$HARNESS"
if [ -d "$REPO" ]; then
  BR=$(git -C "$REPO" branch --show-current 2>/dev/null)
  if [ "$BR" = "main" ] && [ -z "$(git -C "$REPO" status --porcelain)" ]; then
    git -C "$REPO" pull --ff-only --quiet origin main 2>>"$ALERTS" || true
  fi
fi
cd "$WORKDIR" || exit 1

compose() { # compose <stage-file> <runtime-context> -> full prompt on stdout
  printf '%s\n\n%s\n\n%s' "$(cat "$STAGES/$1")" "$(cat "$CTX_FILE")" "$2"
}

beat_company_map() { # send the map (truncated to 64KB) to the cockpit
  [ -s "$MAP" ] || return 0
  head -c 65536 "$MAP" > "$MAP.beat.tmp"
  jq -nc --arg p "$PROJECT" --rawfile m "$MAP.beat.tmp" '{kind:"company_map",project:$p,content:$m}' > "$MAP.payload.tmp"
  "$HARNESS/bin/beat.sh" "$(cat "$MAP.payload.tmp")"
  rm -f "$MAP.beat.tmp" "$MAP.payload.tmp"
}

# ---------- Phase 0: COMPANY MAP (cached; refresh monthly) ----------
MAP_FRESH=false
if [ -s "$MAP" ]; then
  AGE_DAYS=$(( ( $(date +%s) - $(stat -c %Y "$MAP") ) / 86400 ))
  [ "$AGE_DAYS" -lt "$MAP_MAX_AGE_DAYS" ] && MAP_FRESH=true
fi
if [ "$MAP_FRESH" = false ]; then
  RT="RUNTIME CONTEXT
MAP_OUT=$MAP   (write the map HERE)
REPO=$REPO"
  if [ -s "$MAP" ]; then
    RT="$RT

EXISTING MAP (this is a REFRESH — preserve the operator's manual edits unless the codebase proves them wrong):
$(cat "$MAP")"
  fi
  "$HARNESS/bin/agent-call.sh" map "$PROJECT" "$MAP_MODEL" 2400 "$CYCLE_DIR/map.out.txt" "$(compose map.md "$RT")"
  if ! grep -q '^departments:' "$MAP" 2>/dev/null; then
    echo "$(STAMP) [$PROJECT] product: MAP stage failed (no departments frontmatter)" >> "$ALERTS"
  else
    beat_company_map
  fi
fi
cap_stop map

# ---------- PM data signals (BH-7244): read-only evidence for SIGNALS ----------
# CYCLE_DIR is per day: on a failure the else branch removes an earlier
# same-day file, so a stale file is never cited.
DATA_SIGNALS_FILE="$CYCLE_DIR/data-signals.json"
DATA_RT=""
if [ -x "$HARNESS/bin/pm-signals.sh" ] && "$HARNESS/bin/pm-signals.sh" "$PROJECT" "$DATA_SIGNALS_FILE" 2>"$CYCLE_DIR/pm-signals.err" \
   && jq -e '.evidence | type == "array"' "$DATA_SIGNALS_FILE" >/dev/null 2>&1; then
  DATA_RT=$'\n'"DATA_SIGNALS=$DATA_SIGNALS_FILE   (read-only product data evidence; cite evidence_id)"
  DATA_EVIDENCE=$(jq '[.evidence[] | select(.status == "ok")] | length' "$DATA_SIGNALS_FILE")
else
  echo "$(STAMP) [$PROJECT] product: pm-signals failed or missing, SIGNALS runs without data evidence" >> "$LOG"
  rm -f "$DATA_SIGNALS_FILE"
fi

# ---------- Phase 1: SIGNALS ----------
SIGNALS="$CYCLE_DIR/signals.json"
V1_FALLBACK=false
"$HARNESS/bin/agent-call.sh" signals "$PROJECT" "$SIGNALS_MODEL" 3600 "$CYCLE_DIR/signals.out.txt" \
  "$(compose signals.md "RUNTIME CONTEXT
SIGNALS_OUT=$SIGNALS   (write signals HERE)
MAP=$MAP
REPO=$REPO$DATA_RT")"
if ! jq -e '.signals | length > 0' "$SIGNALS" >/dev/null 2>&1; then
  echo "$(STAMP) [$PROJECT] product: SIGNALS failed — falling back to single-session ideation" >> "$ALERTS"
  V1_FALLBACK=true
fi
cap_stop signals

# ---------- Phase 2: IDEATE (fan-out per department) ----------
DEPTS=""
[ -s "$MAP" ] && DEPTS=$(sed -n 's/^departments:[[:space:]]*\[\(.*\)\].*/\1/p' "$MAP" | tr ',' '\n' | tr -d ' "' | grep . || true)
if [ "$V1_FALLBACK" = true ] || [ -z "$DEPTS" ]; then
  [ -z "$DEPTS" ] && echo "$(STAMP) [$PROJECT] product: no departments in map — whole-company fallback" >> "$ALERTS"
  DEPTS="whole-company"
fi

ideate_dept() { # ideate_dept <dept>
  local DEPT="$1"
  local OUT="$CYCLE_DIR/ideas-$DEPT.json"
  local RT="RUNTIME CONTEXT
DEPT=$DEPT
IDEAS_OUT=$OUT   (write ideas HERE)
MAP=$MAP
SIGNALS=$SIGNALS
CATALOG=$CATALOG
LEDGER=$LEDGER
REPO=$REPO"
  if [ "$DEPT" = "whole-company" ]; then
    RT="$RT

FALLBACK MODE: the map and/or signals are unavailable this cycle. Ideate across the WHOLE company directly from the repo, the live board, the catalog, and the ledger — same output schema, 6-10 ideas."
  fi
  "$HARNESS/bin/agent-call.sh" ideate "$PROJECT" "$IDEATE_MODEL" 2400 "$CYCLE_DIR/ideate-$DEPT.out.txt" "$(compose ideate-dept.md "$RT")"
  if ! jq -e '.ideas | length > 0' "$OUT" >/dev/null 2>&1; then
    echo "$(STAMP) [$PROJECT] product: ideate failed for dept=$DEPT (skipped)" >> "$ALERTS"
    rm -f "$OUT"
  fi
}

for DEPT in $DEPTS; do
  while [ "$(jobs -rp | wc -l)" -ge "$IDEATE_CONCURRENCY" ]; do wait -n || true; done
  ideate_dept "$DEPT" &
done
wait
cap_stop ideate

DEPT_FILES=$(ls "$CYCLE_DIR"/ideas-*.json 2>/dev/null || true)
if [ -z "$DEPT_FILES" ]; then
  echo "$(STAMP) [$PROJECT] product: no department produced ideas" >> "$ALERTS"
  echo "$(STAMP) [$PROJECT] product rc=1 :: ideation produced nothing" >> "$LOG"
  exit 1
fi

# ---------- Phase 3: SYNTH ----------
IDEAS="$CYCLE_DIR/ideas.json"
N_FILES=$(wc -w <<<"$DEPT_FILES")
if [ "$N_FILES" -eq 1 ]; then
  cp "$DEPT_FILES" "$IDEAS"
else
  "$HARNESS/bin/agent-call.sh" synth "$PROJECT" "$SYNTH_MODEL" 2400 "$CYCLE_DIR/synth.out.txt" \
    "$(compose synth.md "RUNTIME CONTEXT
CYCLE_DIR=$CYCLE_DIR   (read ideas-*.json here)
IDEAS_OUT=$IDEAS   (write the merged file HERE)
SIGNALS=$SIGNALS
LEDGER=$LEDGER")"
  if ! jq -e '.ideas | length > 0' "$IDEAS" >/dev/null 2>&1; then
    # Synth died: mechanical merge keeps the cycle alive (no cross-dept dedup).
    echo "$(STAMP) [$PROJECT] product: SYNTH failed — mechanical merge" >> "$ALERTS"
    jq -s '{ideas: map(.ideas) | add}' $DEPT_FILES > "$IDEAS"
  fi
fi
pm_ideas_land "$PROJECT" "$CYCLE_DIR" || true
cap_stop synth

# ---------- SELECT (deterministic): DERISK -> UNCLOG -> SCALE, then score ----------
SELECTED="$CYCLE_DIR/selected.json"
jq --slurpfile ledger "$LEDGER" --argjson batch "$PRODUCT_BATCH" --argjson minscore "$PRODUCT_MIN_SCORE" '
  def num: if type=="number" then . elif type=="string" then (([scan("[0-9]+[.]?[0-9]*")] | first // "1") | tonumber) else 1 end;
  [ .ideas[]
    | .impact = (.impact | num) | .confidence = (.confidence | num)
    | .effort = ((.effort | num) | if . < 0.5 then 0.5 else . end)
    | .score = ((.impact * .confidence / .effort) * 10 | round / 10)
    | .dusrank = (if .dus == "derisk" then 0 elif .dus == "unclog" then 1 else 2 end)
    | select(.slug as $s | ($ledger[0] | map(select(.slug == $s and (.status != "candidate" and .status != "expired"))) | length) == 0)
  ] | sort_by([.dusrank, -.score]) as $all
  | { selected: [ $all[] | select(.score >= $minscore) ][:$batch],
      rest:     ([ $all[] | select(.score >= $minscore) ][$batch:] + [ $all[] | select(.score < $minscore) ]) }
' "$IDEAS" > "$SELECTED.tmp" && mv "$SELECTED.tmp" "$SELECTED"

N_SEL=$(jq '.selected | length' "$SELECTED")
NOW="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

# Unselected ideas -> ledger candidates + lightweight cockpit beats.
NEW_CANDS=$(jq -r --slurpfile sel "$SELECTED" '. as $L | $sel[0].rest[] | .slug
  | select(. as $s | ($L | map(.slug == $s) | any | not))' "$LEDGER" 2>/dev/null | sort -u)
jq --slurpfile sel "$SELECTED" --arg now "$NOW" --arg dir "$CYCLE_DIR" '
  . as $L | $L + [ $sel[0].rest[]
    | select(.slug as $s | ($L | map(.slug == $s) | any | not))
    | {slug, title, summary, source, department, role, process, aaa, dus, dus_why,
       impact, effort, confidence, score,
       status: "candidate", rev: 1, dir: $dir, created_at: $now, updated_at: $now} ]
' "$LEDGER" > "$LEDGER.tmp" && mv "$LEDGER.tmp" "$LEDGER"
while IFS= read -r CSLUG; do [ -n "$CSLUG" ] && { prow_put "$PROJECT" "$CSLUG" "$LEDGER" || true; }; done <<<"$NEW_CANDS"
jq -c '.rest[]' "$SELECTED" | while IFS= read -r CAND; do
  "$HARNESS/bin/beat.sh" "$(jq -nc --argjson i "$CAND" --arg p "$PROJECT" \
    '{kind:"proposal",pkey:("prop:"+$p+":"+$i.slug),project:$p,slug:$i.slug,title:$i.title,
      summary:$i.summary,impact:$i.impact,effort:$i.effort,confidence:$i.confidence,
      score:$i.score,dus:($i.dus // ""),dus_why:($i.dus_why // ""),aaa:($i.aaa // ""),
      department:($i.department // ""),status:"candidate",rev:1}')"
done

if [ "$N_SEL" -eq 0 ]; then
  echo "$(STAMP) [$PROJECT] product rc=0 :: ideated $(jq '.ideas|length' "$IDEAS"), none above threshold data_evidence=$DATA_EVIDENCE" >> "$LOG"
  exit 0
fi

# ---------- PRD + MOCKUP per selected idea (shared drafting script) ----------
GATED=0
for i in $(seq 0 $((N_SEL - 1))); do
  IDEA=$(jq -c ".selected[$i]" "$SELECTED")
  SLUG=$(jq -r '.slug' <<<"$IDEA")
  IDIR="$CYCLE_DIR/$SLUG"
  mkdir -p "$IDIR"
  printf '%s' "$IDEA" > "$IDIR/idea.json"

  "$HARNESS/bin/draft-proposal.sh" "$PROJECT" "$IDIR" || continue

  # ---------- GATE ----------
  PKEY="prop:$PROJECT:$SLUG"
  jq --argjson idea "$IDEA" --arg now "$NOW" --arg dir "$IDIR" '
    . + [ $idea + {status: "gate_pending", rev: 1, dir: $dir, created_at: $now, updated_at: $now} ]
  ' "$LEDGER" > "$LEDGER.tmp" && mv "$LEDGER.tmp" "$LEDGER"
  prow_put "$PROJECT" "$SLUG" "$LEDGER" || true

  "$HARNESS/bin/beat.sh" "$(jq -nc --arg pkey "$PKEY" --arg p "$PROJECT" --argjson idea "$IDEA" \
    --arg detail "$(head -c 7000 "$IDIR/prd.md")" \
    '{kind:"proposal",pkey:$pkey,project:$p,slug:$idea.slug,title:$idea.title,summary:$idea.summary,
      impact:$idea.impact,effort:$idea.effort,confidence:$idea.confidence,score:$idea.score,
      dus:($idea.dus // ""),dus_why:($idea.dus_why // ""),aaa:($idea.aaa // ""),
      department:($idea.department // ""),
      status:"gate_pending",rev:1,detail:$detail}')"
  GATED=$((GATED + 1))

  if [ -f "$HARNESS/flags/product-autonomy-$PROJECT" ]; then
    "$HARNESS/bin/post-proposal.sh" "$PROJECT" "$SLUG" >> "$LOG" 2>>"$ALERTS" || true
  fi
done

# ---------- run beat ----------
RUN_START_ISO="$(date -u -d @$RUN_START_EPOCH '+%Y-%m-%dT%H:%M:%SZ')"
COST_USD=$(awk -F, -v p="$PROJECT" -v t0="$RUN_START_ISO" 'BEGIN{s=0} $1>=t0 && $3==p && ($4=="map"||$4=="signals"||$4=="ideate"||$4=="synth"||$4=="prd"||$4=="mockup") {s+=$13} END{printf "%.2f", s}' "$HARNESS/logs/cost.csv" 2>/dev/null)
SUMMARY="product v2: depts=$(wc -w <<<"$DEPTS") signals=$(jq '.signals|length' "$SIGNALS" 2>/dev/null || echo 0) data_evidence=$DATA_EVIDENCE ideated=$(jq '.ideas|length' "$IDEAS") selected=$N_SEL gated=$GATED cost~\$${COST_USD:-?}"
echo "$(STAMP) [$PROJECT] product rc=0 :: $SUMMARY" >> "$LOG"
"$HARNESS/bin/beat.sh" "$(jq -nc --arg rkey "run:$PROJECT:product:$RUN_START_EPOCH" --arg p "$PROJECT" \
  --arg s "$SUMMARY" --arg st "$RUN_START_ISO" --arg fin "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
  '{kind:"run",rkey:$rkey,project:$p,run_kind:"product",rc:0,summary:$s,started_at:$st,finished_at:$fin}')"
exit 0
