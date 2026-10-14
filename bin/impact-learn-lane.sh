#!/bin/bash
# bin/impact-learn-lane.sh — THE HUB LANE THAT TURNS MERGE-QUEUE EJECTIONS INTO
# ONE LEARNED-EDGE PR (BH-6458, slice C1 of BH-6390).
#
#   bin/impact-learn-lane.sh            (no arguments; cron runs it hourly)
#
# gh-rest: no-graphql
#
# WHAT ONE TICK DOES, in order. Each step stops the tick when it fails.
#   1. The open PR. One open PR on impact-learn/edges stops the tick: nothing
#      is read and nothing is written. An open PR older than
#      IMPACT_LEARN_PR_STALE_H pages once (id impact-learn-stale:<n>).
#   2. The events. dqw_events_list reads IMPACT_LEARN_WINDOW_H hours of
#      dequeue_events rows for $HARNESS_REPO.
#   3. The candidates. A row is a candidate only when it is attribution
#      `culprit`, class `rule-break` or `semantic-test`, and names a
#      `tests/…sh` suite (the learner's own event gate). A row already in
#      state/impact-learn/seen.tsv is dropped. The first IMPACT_LEARN_MAX_EVENTS
#      are kept, oldest first. A row with no class yet is not seen, so a later
#      tick reads it again. With no candidate, the tick goes on only when
#      expiry is on and origin/main tracks a learned edge.
#   4. The worktree. A detached scratch worktree of origin/main in the
#      checkout ${REPOS_ROOT:-/root/repos}/<repo>. The lane runs the TREE'S own
#      bin/impact-learn.sh and bin/test-impact.sh, so the reader of the
#      fragments is the one that wrote them.
#   5. The map, built once, and again after each event that wrote an edge.
#      Not built when there is no candidate.
#   6. Each candidate: fetch the head when it is not local, then
#      `bin/impact-learn.sh record --map`. rc 3 is `unreachable`, rc 1 is
#      `failed` (retried next tick), rc 2 is a lane bug and stops the tick.
#   7. Dead edges: a fragment whose path or suite is not in the tree is
#      deleted (the map would drop it anyway).
#   7b. Expiry (BH-6460). An edge expires when its suite passed
#      IMPACT_LEARN_EXPIRE_PASSES times with no failure after the edge's date
#      (0 = off). For each tracked fragment's date D the lane reads
#      sr_passes_list from max(D + 1 day, today - 30 days); the floor is the
#      ledger's own 30-day prune. Then `bin/impact-learn.sh expire` deletes in
#      the worktree. An edge this tick wrote or re-confirmed is kept. A ledger
#      or verb failure deletes nothing, warns once and learning goes on.
#   8. The PR. More new edges, or more expiries, than IMPACT_LEARN_MAX_EDGES
#      opens no PR and pages once (impact-learn-mass, impact-learn-mass-expire).
#      IMPACT_LEARN_ACT=0 prints
#      `would-open` and pushes nothing. Else one commit, a hold_push to
#      impact-learn/edges (leased on the remote head, or `new`), and one POST
#      repos/<slug>/pulls inside the pr-trailers block; only a 201 with a
#      number counts.
#   9. Seen. The rows with outcome edges, none or unreachable go into
#      seen.tsv, and lines older than the window are pruned. Nothing is
#      marked on a failed, mass or dry tick.
#
# OUTPUTS. One tick line in logs/impact-learn.log:
#   <iso> impact-learn <slug> events=<n> candidates=<n> edges=<n> dead=<n>
#     unreachable=<n> failed=<n> expired=<n|-|?>[ truncated] <outcome>
# expired= is `-` when expiry is off or was not checked, `?` when the ledger or
# the expire verb failed, else the deletions in the worktree (git status).
# The learner's lines go to stdout, each prefixed `<repo>#<pr>: `.
# Alerts only through bin/lane-alert.sh --severity warn.
#
# Exit: 0 the tick ran (open, none, mass, would-open, opened) or the gate,
# the hub check or the lock stopped it; 1 a read, the map, the push or the PR
# failed.
#
# OFF: flags/lane-off-impact-learn-lane. Registry: catalog/lanes.d/impact-learn-lane.json.
# Cron: cron/lanes/416-impact-learn-lane.cron. Suite:
# tests/impact-learn-lane.bh-6458-test.sh.
set -uo pipefail
H="${HARNESS:-/root/harness}"

# >>> lane gate (BH-1165): exits 0 on flags/all-off or flags/lane-off-impact-learn-lane.
# shellcheck disable=SC1091
. "$H/bin/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit impact-learn-lane
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    impact-learn-lane
# shellcheck source=bin/lib/env-path.sh
. "$H/bin/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "$H/env"; }
HENV=$(harness_env_dir)
if [ -f "$HENV/global.env" ]; then set -a
  # shellcheck disable=SC1091
  . "$HENV/global.env" 2>/dev/null; set +a; fi
# Again below the env load: global.env re-assigns what the row exported (section
# 16 of tests/lanes-registry-test.sh).
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    impact-learn-lane
export HARNESS="$H"
# shellcheck disable=SC1091
{
  . "$H/bin/lib/hub-box.sh" 2>/dev/null || true
  . "$H/bin/jobs-client.sh" 2>/dev/null || true
  . "$H/bin/lib/gh-rest.sh" 2>/dev/null || true
  . "$H/bin/lib/gh-app-auth.sh" 2>/dev/null || true
  . "$H/bin/lib/pr-trailers.sh" 2>/dev/null || true
  . "$H/bin/lib/hold-push.sh" 2>/dev/null || true
}
# sr_passes_list <repo> <since-day> — GET /api/suite-results/passes (BH-6460):
# per-suite passes and fails since that day. rc 1 on no answer or a bad shape.
sr_passes_list() {
  command -v _jobs_req >/dev/null 2>&1 || return 1
  local out
  out=$(_jobs_req GET "/api/suite-results/passes?repo=$(jq -rn --arg r "$1" '$r|@uri')&since=$2") || return 1
  printf '%s' "$out" | jq -e '(.suites|type) == "array" and all(.suites[]; (.suite|type) == "string"
    and (.passes|type) == "number" and (.fails|type) == "number")' >/dev/null 2>&1 || return 1
  printf '%s\n' "$out"
}
# The suite's seam: a file that redefines the contract functions as recorders.
# Sandbox only, and settable:false in the registry, so no settings row reaches it.
if [ "${HARNESS_TEST_SANDBOX:-}" = 1 ] && [ -n "${IMPACT_LEARN_LANE_FIXTURE:-}" ]; then
  # shellcheck disable=SC1090
  . "$IMPACT_LEARN_LANE_FIXTURE"
fi
for f in is_hub_box local_box_name dqw_events_list gh_rest gh_rest_pr_list gh_default_auth_for_slug \
         pr_trailers_apply hold_push sr_passes_list; do
  command -v "$f" >/dev/null 2>&1 || { echo "impact-learn-lane: $f is missing (bin/lib/)" >&2; exit 1; }
done

is_hub_box "$(local_box_name)" || exit 0

# BH-4080: HARNESS_REPO's default lives in the deployment defaults home.
# shellcheck source=bin/lib/deployment.sh
. "${HARNESS_DEPLOYMENT_FILE-$(dirname "${BASH_SOURCE[0]}")/lib/deployment.sh}" || exit 1
SLUG="$HARNESS_REPO"
REPO_DIR="${REPOS_ROOT:-/root/repos}/${SLUG#*/}"
ST="$H/state/impact-learn"
LOG="$H/logs/impact-learn.log"
BR=impact-learn/edges
LD=catalog/test-impact-learned.d
mkdir -p "$H/logs" "$H/locks" "$ST" 2>/dev/null
exec 9>"$H/locks/impact-learn.lock" || exit 0
flock -n 9 || { echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ') impact-learn another tick holds the lock, skipping" >> "$LOG"; exit 0; }

# kint <value> <default> <min> <max> — an int knob, the default when invalid or out of range.
kint() {
  case "$1" in ''|*[!0-9]*) printf '%s' "$2"; return ;; esac
  [ "${#1}" -le 6 ] && [ "$((10#$1))" -ge "$3" ] && [ "$((10#$1))" -le "$4" ] \
    && printf '%s' "$((10#$1))" || printf '%s' "$2"
}
IMPACT_LEARN_ACT=$(kint "${IMPACT_LEARN_ACT:-1}" 1 0 1)
IMPACT_LEARN_WINDOW_H=$(kint "${IMPACT_LEARN_WINDOW_H:-168}" 168 1 720)
IMPACT_LEARN_MAX_EVENTS=$(kint "${IMPACT_LEARN_MAX_EVENTS:-50}" 50 1 500)
IMPACT_LEARN_MAX_EDGES=$(kint "${IMPACT_LEARN_MAX_EDGES:-30}" 30 1 200)
IMPACT_LEARN_MAX_PATHS=$(kint "${IMPACT_LEARN_MAX_PATHS:-10}" 10 1 100)
IMPACT_LEARN_PR_STALE_H=$(kint "${IMPACT_LEARN_PR_STALE_H:-48}" 48 1 720)
IMPACT_LEARN_EXPIRE_PASSES=$(kint "${IMPACT_LEARN_EXPIRE_PASSES:-30}" 30 0 1000)
# The one clock read. IMPACT_LEARN_NOW is the suite's seam.
case "${IMPACT_LEARN_NOW:-}" in ''|*[!0-9]*) NOW=$(date -u +%s) ;; *) NOW=$IMPACT_LEARN_NOW ;; esac
ISO=$(date -u -d "@$NOW" '+%Y-%m-%dT%H:%M:%SZ')
SINCE=$(date -u -d "@$((NOW - IMPACT_LEARN_WINDOW_H * 3600))" '+%Y-%m-%dT%H:%M:%SZ')

N_EVENTS=0 N_CAND=0 N_EDGES=0 N_DEAD=0 N_UNREACH=0 N_FAILED=0 EXPIRED='-' TRUNC=""
tick() { # tick <outcome> — the one log line of this run.
  echo "$ISO impact-learn $SLUG events=$N_EVENTS candidates=$N_CAND edges=$N_EDGES dead=$N_DEAD unreachable=$N_UNREACH failed=$N_FAILED expired=$EXPIRED$TRUNC $1" >> "$LOG"
}
warn() { # warn <id> <text>
  "$H/bin/lane-alert.sh" --severity warn --id "$1" impact-learn-lane "$2" >/dev/null 2>&1
}

d=$(mktemp -d "${TMPDIR:-/tmp}/impact-learn.XXXXXX") || { tick mktemp-failed; exit 1; }
WT="$d/wt"
cleanup() {
  case "$d" in "${TMPDIR:-/tmp}"/impact-learn.?*) rm -rf "$d" ;; esac
  git -C "$REPO_DIR" worktree prune >/dev/null 2>&1
}
trap cleanup EXIT

# ── 1. the open PR ──────────────────────────────────────────────────────────
rc=0; gh_rest_pr_list "$SLUG" open "${SLUG%%/*}:$BR" > "$d/open.json" 2>/dev/null || rc=$?
if [ "$rc" != 0 ] || ! jq -e 'type == "array"' "$d/open.json" >/dev/null 2>&1; then
  tick pr-list-unreadable; exit 1
fi
if [ "$(jq 'length' "$d/open.json")" -gt 0 ]; then
  pn=$(jq -r '.[0].number // ""' "$d/open.json")
  pat=$(jq -r '.[0].created_at // ""' "$d/open.json")
  pts=""; [ -n "$pat" ] && { pts=$(date -u -d "$pat" +%s 2>/dev/null) || pts=""; }
  if [ -n "$pts" ] && [ $((NOW - pts)) -gt $((IMPACT_LEARN_PR_STALE_H * 3600)) ]; then
    warn "impact-learn-stale:$pn" \
      "learned-edge PR #$pn has been open $(( (NOW - pts) / 3600 ))h; the lane learns nothing new until it merges or closes"
  fi
  tick "open #$pn"; exit 0
fi

# ── 2. the events ───────────────────────────────────────────────────────────
rc=0; dqw_events_list "$SLUG" "" "$SINCE" > "$d/events.json" 2>/dev/null || rc=$?
if [ "$rc" != 0 ] || ! jq -e '(.rows|type) == "array"' "$d/events.json" >/dev/null 2>&1; then
  warn impact-learn-events "dequeue_events for $SLUG since $SINCE could not be read; no edge learned this tick"
  tick events-unreadable; exit 1
fi
N_EVENTS=$(jq '.rows | length' "$d/events.json")
[ "$(jq -r '.truncated' "$d/events.json")" = true ] && TRUNC=" truncated"

# ── 3. the candidates ───────────────────────────────────────────────────────
# seen.tsv: `<repo>#<pr> <head> <run_id>\t<created_at>\t<outcome>`.
SEEN="$ST/seen.tsv"
[ -f "$SEEN" ] || : > "$SEEN"
jq -c --rawfile seen "$SEEN" '
  ($seen | split("\n") | map(split("\t")[0]) | map(select(. != ""))) as $s
  | .rows[]
  | select(.attribution == "culprit" and (.class == "rule-break" or .class == "semantic-test"))
  | select((.suites // "" | tostring) | [splits("[\\s,]+")] | any(test("^tests/(mc/)?[A-Za-z0-9._-]+\\.sh$")))
  | (.key = "\(.repo)#\(.pr) \(.head) \(.run_id)")
  | select(.key as $k | $s | index([$k]) | not)' "$d/events.json" 2>/dev/null \
  | head -n "$IMPACT_LEARN_MAX_EVENTS" > "$d/cand"
N_CAND=$(grep -c . "$d/cand")
: > "$d/outcomes"; : > "$d/written"; : > "$d/keep"

# mark_seen — appends the outcomes that end a row, then prunes the lines older
# than the window. tmp + mv; a failed write only makes a later tick re-read.
mark_seen() {
  { cat "$SEEN"
    awk -F'\t' '$3 == "edges" || $3 == "none" || $3 == "unreachable"' "$d/outcomes"
  } | awk -F'\t' -v since="$SINCE" 'NF >= 3 && $2 >= since' > "$SEEN.tmp" && mv -f "$SEEN.tmp" "$SEEN"
}

# No candidate: the tick goes on only to expire, when expiry is on and
# origin/main tracks at least one learned edge.
if [ "$N_CAND" = 0 ]; then
  n_tracked=0
  if [ "$IMPACT_LEARN_EXPIRE_PASSES" -gt 0 ] && git -C "$REPO_DIR" rev-parse --git-dir >/dev/null 2>&1 \
     && git -C "$REPO_DIR" fetch -q origin main >/dev/null 2>&1; then
    n_tracked=$(git -C "$REPO_DIR" ls-tree --name-only origin/main -- "$LD/" 2>/dev/null | grep -cE "^$LD/[0-9a-f]{16}\.tsv\$")
  fi
  if [ "$n_tracked" = 0 ]; then mark_seen; tick none; exit 0; fi
fi

# ── 4. the worktree ─────────────────────────────────────────────────────────
if ! git -C "$REPO_DIR" rev-parse --git-dir >/dev/null 2>&1; then
  warn impact-learn-norepo "$REPO_DIR is not a git checkout of $SLUG; no edge learned"
  tick norepo; exit 1
fi
git -C "$REPO_DIR" fetch -q origin main >/dev/null 2>&1 || { tick fetch-failed; exit 1; }
git -C "$REPO_DIR" worktree add -q -f --detach "$WT" origin/main >/dev/null 2>&1 || { tick worktree-failed; exit 1; }
if [ ! -x "$WT/bin/impact-learn.sh" ]; then
  warn impact-learn-nolearner "origin/main of $SLUG has no executable bin/impact-learn.sh; no edge learned"
  tick nolearner; exit 1
fi

# ── 5. the map ──────────────────────────────────────────────────────────────
build_map() {
  "$WT/bin/test-impact.sh" --root "$WT" map < /dev/null > "$d/map" 2>/dev/null && [ -s "$d/map" ] && return 0
  warn impact-learn-map "bin/test-impact.sh map failed in a worktree of origin/main of $SLUG; no edge learned"
  tick map-failed; exit 1
}
[ "$N_CAND" -gt 0 ] && build_map

# ── 6. each candidate ───────────────────────────────────────────────────────
while IFS= read -r ev; do
  printf '%s\n' "$ev" > "$d/ev.json"
  IFS=$'\t' read -r key at pr head label < <(jq -r '[.key, .created_at, (.pr|tostring), .head, "\(.repo)#\(.pr)"] | join("\t")' "$d/ev.json")
  if ! git -C "$REPO_DIR" cat-file -e "$head^{commit}" 2>/dev/null; then
    git -C "$REPO_DIR" fetch -q --no-tags origin "refs/pull/$pr/head" >/dev/null 2>&1 < /dev/null \
      || git -C "$REPO_DIR" fetch -q --no-tags origin "$head" >/dev/null 2>&1 < /dev/null || true
  fi
  rc=0
  "$WT/bin/impact-learn.sh" record --event "$d/ev.json" --root "$WT" --base origin/main \
    --map "$d/map" --max-paths "$IMPACT_LEARN_MAX_PATHS" < /dev/null > "$d/rec.out" 2>&1 || rc=$?
  sed "s|^|$label: |" "$d/rec.out"
  case "$rc" in
    0) w=$(sed -n 's/^impact-learn: event .* written=\([0-9][0-9]*\) .*/\1/p' "$d/rec.out" | tail -1)
       if [ "${w:-0}" -gt 0 ]; then out=edges; build_map; else out=none; fi
       awk -v k="$key" '$1 == "edge" { printf "%s\t%s\n", k, $NF }' "$d/rec.out" >> "$d/written"
       awk '$1 == "edge" || $1 == "exists" { n = split($NF, a, "/"); print a[n] }' "$d/rec.out" >> "$d/keep" ;;
    3) out=unreachable; N_UNREACH=$((N_UNREACH + 1)) ;;
    1) out=failed; N_FAILED=$((N_FAILED + 1)) ;;
    *) warn impact-learn-usage "bin/impact-learn.sh record refused the lane's arguments (rc $rc) for $label; the lane is broken"
       tick usage; exit 1 ;;
  esac
  printf '%s\t%s\t%s\n' "$key" "$at" "$out" >> "$d/outcomes"
done < "$d/cand"

# ── 7. dead edges ───────────────────────────────────────────────────────────
git -C "$WT" status --porcelain --untracked-files=all > "$d/status" 2>/dev/null
while IFS= read -r line; do
  f="${line#?? }"
  case "$line" in "?? $LD/"*.tsv) ;; *) continue ;; esac
  IFS=$'\t' read -r p s _ < <(grep -v '^#' "$WT/$f" | head -1)
  if { [ "$p" != '*' ] && [ ! -e "$WT/${p%/}" ]; } || [ ! -f "$WT/$s" ]; then
    rm -f "$WT/$f"; N_DEAD=$((N_DEAD + 1))
  fi
done < "$d/status"

# An event whose every edge was dead taught nothing: its outcome is none.
while IFS=$'\t' read -r k a o; do
  if [ "$o" = edges ]; then
    o=none
    while IFS=$'\t' read -r wk wf; do [ "$wk" = "$k" ] && [ -e "$wf" ] && { o=edges; break; }; done < "$d/written"
  fi
  printf '%s\t%s\t%s\n' "$k" "$a" "$o"
done < "$d/outcomes" > "$d/outcomes.tmp" && mv -f "$d/outcomes.tmp" "$d/outcomes"

# ── 7b. expiry ──────────────────────────────────────────────────────────────
# The floor is the ledger's own prune (PRUNE_AFTER_S, 30 days, in
# worker/jobs/src/routes/suite-results.js): rows before it are gone, so no read
# goes further back, and a tick makes at most 31 reads.
: > "$d/expired"
if [ "$IMPACT_LEARN_EXPIRE_PASSES" -gt 0 ]; then
  TODAY=$(date -u -d "@$NOW" +%F)
  FLOOR=$(date -u -d "@$((NOW - 30 * 86400))" +%F)
  git -C "$WT" ls-files -- "$LD" 2>/dev/null | grep -E "^$LD/[0-9a-f]{16}\.tsv\$" > "$d/tracked"
  if [ ! -s "$d/tracked" ]; then
    EXPIRED=0
  else
    # The distinct edge dates. A file with no readable date is left to the verb.
    while IFS= read -r f; do
      grep -v '^#' "$WT/$f" | head -1 | cut -f4
    done < "$d/tracked" | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' | LC_ALL=C sort -u > "$d/dates"
    : > "$d/counts"; ledger_ok=1
    declare -A SINCE_READ=()
    while IFS= read -r day; do
      since=$(date -u -d "$day + 1 day" +%F 2>/dev/null) || continue
      [[ "$since" < "$FLOOR" ]] && since="$FLOOR"
      [[ "$since" > "$TODAY" ]] && continue
      if [ -z "${SINCE_READ[$since]+x}" ]; then
        if ! sr_passes_list "$SLUG" "$since" > "$d/passes-$since.json" 2>/dev/null; then
          ledger_ok=0; break
        fi
        SINCE_READ[$since]=1
      fi
      jq -r --arg d "$day" '.suites[] | [$d, .suite, (.passes|tostring), (.fails|tostring)] | join("\t")' \
        "$d/passes-$since.json" >> "$d/counts" || { ledger_ok=0; break; }
    done < "$d/dates"
    if [ "$ledger_ok" = 0 ]; then
      EXPIRED='?'
      warn impact-learn-ledger "the suite_results pass counts for $SLUG could not be read; no learned edge expired this tick"
    else
      rc=0
      "$WT/bin/impact-learn.sh" expire --counts "$d/counts" --passes "$IMPACT_LEARN_EXPIRE_PASSES" \
        --out-dir "$WT/$LD" --keep "$d/keep" < /dev/null > "$d/exp.out" 2>&1 || rc=$?
      sed 's|^|expire: |' "$d/exp.out"
      if [ "$rc" = 0 ]; then
        grep '^expire ' "$d/exp.out" > "$d/expired"
        EXPIRED=0
      else
        git -C "$WT" checkout -q HEAD -- "$LD" >/dev/null 2>&1
        EXPIRED='?'
        warn impact-learn-expire "bin/impact-learn.sh expire failed (rc $rc) in a worktree of origin/main of $SLUG; no learned edge expired this tick"
      fi
    fi
  fi
fi

# ── 8. the dirty guard and the edge count ───────────────────────────────────
git -C "$WT" status --porcelain --untracked-files=all > "$d/status" 2>/dev/null
ok_re="^\?\? $LD/[0-9a-f]{16}\.tsv\$"
case "$EXPIRED" in ''|*[!0-9]*) ;; *) ok_re="^(\?\?| D) $LD/[0-9a-f]{16}\.tsv\$" ;; esac
dirty=$(grep -Ev "$ok_re" "$d/status" | head -1)
if [ -n "$dirty" ]; then
  warn impact-learn-dirty "the learner left '$dirty' in the worktree of $SLUG; no PR opened"
  tick dirty; exit 1
fi
N_EDGES=$(grep -c '^?? ' "$d/status")
case "$EXPIRED" in ''|*[!0-9]*) N_EXP=0 ;; *) EXPIRED=$(grep -c '^ D ' "$d/status"); N_EXP=$EXPIRED ;; esac
if [ "$N_EDGES" = 0 ] && [ "$N_EXP" = 0 ]; then mark_seen; tick none; exit 0; fi
if [ "$N_EDGES" -gt "$IMPACT_LEARN_MAX_EDGES" ]; then
  warn impact-learn-mass "$N_EDGES new learned edges from $N_CAND events is over IMPACT_LEARN_MAX_EDGES=$IMPACT_LEARN_MAX_EDGES; no PR opened"
  tick mass; exit 0
fi
if [ "$N_EXP" -gt "$IMPACT_LEARN_MAX_EDGES" ]; then
  warn impact-learn-mass-expire "$N_EXP learned edges to expire is over IMPACT_LEARN_MAX_EDGES=$IMPACT_LEARN_MAX_EDGES; no PR opened"
  tick mass; exit 0
fi

# The edge list, one line per new fragment: `<path>\t<suite>\t<source>\t<date>`.
sed -n 's/^?? //p' "$d/status" | LC_ALL=C sort | while IFS= read -r f; do grep -v '^#' "$WT/$f" | head -1; done > "$d/edges"
# The expired list, one line per deleted fragment: the data line from HEAD,
# then `\t<passes>` from the verb's `expire` line for that file.
sed -n 's/^ D //p' "$d/status" | LC_ALL=C sort | while IFS= read -r f; do
  pp=$(awk -v b="${f##*/}" '{ n = split($(NF-1), a, "/"); if (a[n] == b) { sub(/^passes=/, "", $NF); print $NF } }' "$d/expired")
  printf '%s\t%s\n' "$(git -C "$WT" show "HEAD:$f" 2>/dev/null | grep -v '^#' | head -1)" "${pp:-?}"
done > "$d/exprows"
if [ "$N_EDGES" -gt 0 ] && [ "$N_EXP" -gt 0 ]; then
  TITLE="chore(test-impact): learn $N_EDGES and expire $N_EXP impact edge(s)"
elif [ "$N_EDGES" -gt 0 ]; then
  TITLE="chore(test-impact): learn $N_EDGES impact edge(s) from merge-queue ejections"
else
  TITLE="chore(test-impact): expire $N_EXP impact edge(s) after clean passes"
fi

# ── 9. the PR ───────────────────────────────────────────────────────────────
if [ "$IMPACT_LEARN_ACT" = 0 ]; then
  echo "would-open edges=$N_EDGES expired=$N_EXP"
  awk -F'\t' '{ printf "  %s -> %s (%s, %s)\n", $1, $2, $3, $4 }' "$d/edges"
  awk -F'\t' '{ printf "  expire %s -> %s (passes=%s)\n", $1, $2, $5 }' "$d/exprows"
  tick would-open; exit 0
fi
git -C "$WT" add -A -- "$LD" >/dev/null 2>&1 \
  && git -C "$WT" -c user.name=impact-learn -c user.email=harness@box \
       commit -q -m "$TITLE" >/dev/null 2>&1 \
  || { tick commit-failed; exit 1; }
gh_default_auth_for_slug "$SLUG" >/dev/null 2>&1 || { tick auth-failed; exit 1; }
# The push goes through hold_push (BH-2504), never a raw git push. The branch is
# the lane's own and has no ticket (`none`). Step 1 proved no open PR uses it,
# so a branch left by a closed PR is replaced: the lease is the sha the remote
# holds now (read here, just before the push), or `new` when there is none. A
# push from anyone between this read and the push makes git refuse it.
lease=""
if ! lease=$(git -C "$WT" ls-remote origin "refs/heads/$BR" 2>/dev/null | cut -f1); then
  warn impact-learn-push "the remote head of $BR on $SLUG could not be read; no PR opened"
  tick push-failed; exit 1
fi
if ! hold_push "${SLUG#*/}" none "$WT" origin HEAD "$BR" "${lease:-new}" >/dev/null 2>&1; then
  warn impact-learn-push "the push of $BR to $SLUG failed; no PR opened"
  tick push-failed; exit 1
fi
{ if [ "$N_EDGES" -gt 0 ]; then
    printf 'The merge queue ejected these culprits for a suite the impact map did not select.\n'
    printf 'Each row below adds that suite to the selection for the path, so the builder gate runs it next time.\n\n'
    awk -F'\t' '{ printf "- `%s` → `%s` (from %s, %s)\n", $1, $2, $3, $4 }' "$d/edges"
  fi
  if [ "$N_EXP" -gt 0 ]; then
    [ "$N_EDGES" -gt 0 ] && printf '\n'
    printf 'Expired (passed ≥%s times with no failure since the edge'"'"'s date):\n\n' "$IMPACT_LEARN_EXPIRE_PASSES"
    awk -F'\t' '{ printf "- `%s` → `%s` (from %s, %s; passed %s times)\n", $1, $2, $3, $4, $5 }' "$d/exprows"
  fi
  printf '\nEvents read: %s. Candidates: %s. Edges: %s. Dead edges dropped: %s. Unreachable heads: %s. Expired: %s.\n' \
    "$N_EVENTS" "$N_CAND" "$N_EDGES" "$N_DEAD" "$N_UNREACH" "$N_EXP"
  printf '\nA new row adds a suite to a selection. A row expires when its suite passed IMPACT_LEARN_EXPIRE_PASSES (%s) times with no failure after the row'"'"'s date, read from the suite_results ledger.\n' \
    "$IMPACT_LEARN_EXPIRE_PASSES"
} > "$d/body"
# >>> pr trailers (BH-3987)
pr_trailers_apply "$d/body" lane:impact-learn-lane none \
  || echo "impact-learn-lane: pr trailers: could not write $d/body; the PR opens without trailers" >&2
jq -n --arg t "$TITLE" \
  --arg h "$BR" --rawfile b "$d/body" '{title: $t, head: $h, base: "main", body: $b}' > "$d/pr.json"
rc=0; gh_rest POST "repos/$SLUG/pulls" --input "$d/pr.json" > "$d/pr.out" 2>/dev/null || rc=$?
# <<< pr trailers
prn=$(jq -e '.number | numbers' "$d/pr.out" 2>/dev/null) || prn=""
if [ "$rc" != 0 ] || [ "${GH_REST_STATUS:-}" != 201 ] || [ -z "$prn" ]; then
  warn impact-learn-pr "opening the PR for $BR on $SLUG was refused (HTTP ${GH_REST_STATUS:-?}); the next tick retries"
  tick pr-failed; exit 1
fi
mark_seen
tick "opened #$prn"
exit 0
