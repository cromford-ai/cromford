#!/bin/bash
# bin/flaky-detect.sh <project|owner/repo> [--dry-run] [--days N] [--min N]
#
# Reads a repo's recent workflow runs and classifies every RED head:
#
#   flake   the same workflow concluded BOTH failure and success on this head
#           sha. Same tree, same lockfile, same workflow file, two answers —
#           the code did not change, so the test did not either. (The sha is
#           what makes "no push in between" a fact: a push is a new sha and
#           therefore a different group.)
#   red     the workflow went red on this head and never went green on it. A
#           real red until something proves otherwise.
#
# BOTH kinds are written to the ledger, and that is the point of the table's
# name being a little wrong. A "flakes" table holding only flakes can tell you
# a number went up and nothing else; flaky reds OVER ALL reds is the measure
# anyone would actually act on, and a denominator that lives somewhere else is
# a denominator that stops matching the numerator. One table, one scan, one
# rate — bin/pipeline-health.sh reads exactly these rows.
#
# The unit of evidence is the HEAD, not the run and not the row: a head that
# was re-run nine times is one piece of evidence about one test, which is why
# every count downstream is over DISTINCT heads.
#
# READ-ONLY against GitHub. The only writes are ledger rows (and none at all
# under --dry-run). Nothing here re-runs, merges, comments or closes anything —
# the one rerun the fleet takes is the merge conductor's, on a red it is about
# to count, and it is deliberately not this lane's to make.
#
#   bin/flaky-detect.sh project-3                  # 14d, writes rows, prints the table
#   bin/flaky-detect.sh example-org/project-3 --dry-run
#   bin/flaky-detect.sh project-3 --days 30 --min 2
#
# Cost: one paged runs listing per repo, plus one jobs read and (capped) one
# --log-failed read per red run in the window. Run it daily, not per tick.
set -uo pipefail
H="${HARNESS:-/root/harness}"
. "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$H")

# >>> lane gate (BH-1165) — one off-switch and one source of numbers for this
# lane. lane_gate_or_exit exits 0 when flags/all-off, flags/lane-off-flaky-detect
# (or a pause_flags row driving either) is set; lane_env_apply then puts this
# lane's settings rows into the environment its own ${KNOB:-default} reads use.
# Both fail OPEN: an unreachable worker leaves the lane exactly as it is today.
# Registry: catalog/lanes.json. Operator: bin/harness-ctl.sh off flaky-detect.
# shellcheck disable=SC1091
. "${HARNESS:-/root/harness}/bin/lib/lane-gate.sh" 2>/dev/null || true
# The project is the claim key (BH-7422): the 05:40 loop and a wake class's
# per-project launch of another project must not turn each other away. A slug
# (owner/repo) or a flag is not a key; that run gates lane-wide as before.
case "${1:-}" in ''|-*|*/*) _FD_GP="" ;; *) _FD_GP="$1" ;; esac
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit flaky-detect "${_FD_GP:-}"
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    flaky-detect
export HARNESS="$H"
[ -f "$H/fleet.conf" ] && export FLEET_CONF="${FLEET_CONF:-$H/fleet.conf}"
if [ -f "$HENV/global.env" ]; then set -a; # shellcheck disable=SC1091
  . "$HENV/global.env"; set +a; fi
# AND AGAIN, BELOW THE ENV LOAD (BH-1165 review). `set -a; . env/global.env`
# re-assigns every name it carries, so the call above lost each knob the box's
# env file also sets — the settings row was gone, the page went on reporting
# `source: settings`, and nothing errored: the exact shape this ticket exists to
# end. The call above still earns its place: the knobs this lane reads BEFORE
# this line have no other way to see a row. Applying twice is idempotent (the
# settings cache is already warm) and section 16 of tests/lanes-registry-test.sh
# is the ordering.
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    flaky-detect
# shellcheck source=/dev/null
[ -r "$H/bin/jobs-client.sh" ] && . "$H/bin/jobs-client.sh"
# shellcheck source=bin/lib/gh-repo-token.sh
[ -r "$H/bin/lib/gh-repo-token.sh" ] && . "$H/bin/lib/gh-repo-token.sh"
# shellcheck source=bin/lib/gh-app-auth.sh
[ -r "$H/bin/lib/gh-app-auth.sh" ] && . "$H/bin/lib/gh-app-auth.sh"
# shellcheck source=bin/lib/flaky.sh
. "$H/bin/lib/flaky.sh"

STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
TARGET=""; DRY=0; DAYS="$FLAKY_WINDOW_DAYS"; MIN="$FLAKY_MIN"
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run|-n) DRY=1; shift ;;
    --days) DAYS="${2:-14}"; shift 2 ;;
    --min)  MIN="${2:-3}"; shift 2 ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) [ -n "$TARGET" ] || TARGET="$1"; shift ;;
  esac
done
[ -n "$TARGET" ] || { echo "usage: flaky-detect.sh <project|owner/repo> [--dry-run] [--days N] [--min N]" >&2; exit 2; }
  # >>> BH-1061 wake backstop
  if [ -r "$H/bin/lib/wake-lanes.sh" ]; then
    # shellcheck source=bin/lib/wake-lanes.sh
    . "$H/bin/lib/wake-lanes.sh"
  fi
  if command -v wake_backstop_skip >/dev/null 2>&1 && wake_backstop_skip flaky-detect "$TARGET" 43200; then
    exit 0
  fi
  # <<< BH-1061 wake backstop
 case "$DAYS" in ''|*[!0-9]*) DAYS=14 ;; esac
case "$MIN"  in ''|*[!0-9]*) MIN=3 ;; esac

case "$TARGET" in
  */*) SLUG="$TARGET" ;;
  *)   SLUG=$("$H/bin/fleet-conf.sh" "$TARGET" repo 2>/dev/null) ;;
esac
[ -n "${SLUG:-}" ] && [ "$SLUG" != "-" ] || { echo "flaky-detect: no repo for '$TARGET'" >&2; exit 2; }
if command -v gh_repo_use_token >/dev/null 2>&1; then
  gh_repo_use_token "$SLUG" || {
    command -v gh_repo_invisible_alert >/dev/null 2>&1 && \
      gh_repo_invisible_alert flaky-detect "$SLUG" "flake detection cannot list its workflow runs"
    exit 1; }
fi
# #425: one repo for the whole run — arm after the PAT probe so the App token wins when armed.
command -v gh_auth_for >/dev/null 2>&1 && gh_auth_for "$SLUG" || true
SINCE=$(flaky_since_date "$DAYS")
LOG="$H/logs/flaky-detect.log"; mkdir -p "$H/logs" 2>/dev/null

# ── 1. the runs, paged ──────────────────────────────────────────────────────
# `created=>=` is GitHub's own filter, so the window is enforced server-side and
# a busy repo does not page forever. FLAKY_PAGES caps it anyway: a repo that
# somehow has more than 500 runs in the window gets the newest 500, which is the
# half that can still be acted on.
ALL='[]'; PAGE=1
while [ "$PAGE" -le "${FLAKY_PAGES:-5}" ]; do
  P=$(gh api -X GET "repos/$SLUG/actions/runs" -f per_page=100 -f page="$PAGE" -f "created=>=$SINCE" \
        -q '[.workflow_runs[]? | {i:.id, n:.name, p:.path, s:.status, c:.conclusion, h:.head_sha, t:.created_at, u:.html_url}]' 2>/dev/null) || break
  [ -n "$P" ] && [ "$P" != "[]" ] || break
  ALL=$(jq -cn --argjson a "$ALL" --argjson b "$P" '$a + $b' 2>/dev/null) || break
  [ "$(jq 'length' <<<"$P" 2>/dev/null || echo 0)" -lt 100 ] && break
  PAGE=$((PAGE+1))
done
if [ "$ALL" = '[]' ]; then
  echo "$(STAMP) $SLUG: no workflow runs since $SINCE (or the listing failed)" >> "$LOG"
  echo "flaky-detect $SLUG — no runs since $SINCE"
  command -v gh_repo_token_reset >/dev/null 2>&1 && gh_repo_token_reset
  exit 0
fi

# ── 2. classify every (workflow, head) group ────────────────────────────────
# NOT named GROUPS. `GROUPS` is a bash special array (the caller's group list);
# assignments to it are silently ignored and `$GROUPS` expands to the first gid,
# so this block read "0" as root and "20" on a mac while looking completely
# correct. Cost an hour. Same family as HEAD/PATH/SECONDS — check before reusing
# an obvious all-caps name.
FGROUPS=$(python3 - "$ALL" <<'PYEOF' 2>/dev/null
import json, sys
try: runs = json.loads(sys.argv[1])
except Exception: sys.exit(0)
RED = {"failure", "timed_out", "startup_failure"}
by = {}
for r in runs:
    if not isinstance(r, dict) or r.get("s") != "completed": continue
    c = r.get("c")
    # cancelled / skipped / neutral are not evidence in either direction: a
    # cancelled run says the operator pressed stop, not that the code is bad.
    if c not in RED and c != "success": continue
    head = r.get("h") or ""
    path = r.get("p") or r.get("n") or "?"
    if not head: continue
    g = by.setdefault((path, head), {"red": [], "green": 0, "name": r.get("n") or path, "day": ""})
    day = (r.get("t") or "")[:10]
    if day > g["day"]: g["day"] = day
    if c == "success": g["green"] += 1
    else: g["red"].append(str(r.get("i") or ""))
for (path, head), g in sorted(by.items()):
    if not g["red"]: continue
    kind = "flake" if g["green"] else "red"
    print("\t".join([kind, path, g["name"], head, g["day"], ",".join(x for x in g["red"] if x)]))
PYEOF
)
if [ -z "$FGROUPS" ]; then
  echo "$(STAMP) $SLUG: $(jq 'length' <<<"$ALL") run(s) since $SINCE, no red head" >> "$LOG"
  echo "flaky-detect $SLUG — no red head since $SINCE"
  command -v gh_repo_token_reset >/dev/null 2>&1 && gh_repo_token_reset
  exit 0
fi

# ── 3. name what failed, and ledger it ──────────────────────────────────────
ROWS=$(mktemp); trap 'rm -f "$ROWS"' EXIT
NFLAKE=0; NRED=0; NROWS=0
while IFS=$'\t' read -r KIND WPATH WNAME WHEAD DAY IDS; do
  [ -n "$KIND" ] && [ -n "$WHEAD" ] || continue
  [ "$KIND" = flake ] && NFLAKE=$((NFLAKE+1)) || NRED=$((NRED+1))
  NAMES=""
  OLDIFS=$IFS; IFS=,
  for RID in $IDS; do
    [ -n "$RID" ] || continue
    TN=$(flaky_run_tests "$SLUG" "$RID" 2>/dev/null) || continue
    NAMES="${NAMES}${TN}"$'\n'
  done
  IFS=$OLDIFS
  # A red we cannot name at all still counts, as the workflow itself: dropping
  # it would quietly shrink the denominator and make the fleet look less flaky
  # than it is, which is the one direction this measurement must not lean.
  NAMES=$(printf '%s' "$NAMES" | grep -av '^$' | awk '!seen[$0]++')
  [ -n "$NAMES" ] || NAMES="workflow:$WPATH"
  while IFS= read -r N; do
    [ -n "$N" ] || continue
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$DAY" "$SLUG" "$WPATH" "$N" "$WHEAD" "$KIND" >> "$ROWS"
    NROWS=$((NROWS+1))
    [ "$DRY" = 1 ] && continue
    command -v metric_flake >/dev/null 2>&1 && \
      metric_flake "$SLUG" "$WPATH" "$N" "$WHEAD" "$DAY" "$KIND" || true
  done <<<"$NAMES"
done <<<"$FGROUPS"

# ── 4. the table: distinct-head flake counts over the window ────────────────
# This run's rows UNION whatever the ledger already holds, so the count is the
# window's count and not this run's — a detector that printed only what it just
# saw would reset the evidence every time it ran.
LEDGER=""
command -v metric_flakes_list >/dev/null 2>&1 && \
  LEDGER=$(metric_flakes_list 2000 "$SLUG" "$SINCE" 2>/dev/null || true)
REDS=$( { printf '%s\n' "$LEDGER"; cat "$ROWS"; } | awk -F'\t' -v s="$SINCE" -v r="$SLUG" '
  $2==r && $1>=s && $6!="" { k=$3 SUBSEP $5; if (!(k in seen)) { seen[k]=1; t++; if ($6=="flake") f++ } }
  END { printf "%d %d", f+0, t+0 }')
read -r FHEADS THEADS <<<"$REDS"
RATE="-"; [ "${THEADS:-0}" -gt 0 ] && RATE="$(( 100 * FHEADS / THEADS ))%"
echo "flaky-detect $SLUG — window ${DAYS}d since $SINCE${DRY:+}$([ "$DRY" = 1 ] && echo "  (dry-run: nothing written)")"
echo "  red heads: $THEADS   flaky: $FHEADS   flake rate: $RATE   this run: $NFLAKE flake / $NRED red group(s), $NROWS row(s)"
echo ""
printf '  %-5s  %-38s  %s\n' heads workflow "test (>=$MIN heads = quarantine candidate)"
{ printf '%s\n' "$LEDGER"; cat "$ROWS"; } | awk -F'\t' -v s="$SINCE" -v r="$SLUG" '
  $2==r && $1>=s && $6=="flake" && $4!="" {
    k=$3 SUBSEP $4 SUBSEP $5; if (k in seen) next; seen[k]=1
    n[$3 SUBSEP $4]++
  }
  END { for (k in n) { split(k, a, SUBSEP); printf "%d\t%s\t%s\n", n[k], a[1], a[2] } }' \
  | sort -rn -k1,1 | head -40 \
  | while IFS=$'\t' read -r C W N; do
      MARK=" "; [ "${C:-0}" -ge "$MIN" ] && MARK="*"
      printf '%s %-5s  %-38s  %s\n' "$MARK" "$C" "$W" "$N"
    done
echo ""
echo "  * = in the quarantine window (bin/flaky-quarantine.sh $TARGET adds it to ci/flaky.txt). docs/FLAKY-TESTS.md"
echo "$(STAMP) $SLUG since=$SINCE groups=$((NFLAKE+NRED)) flake=$NFLAKE red=$NRED rows=$NROWS heads=$FHEADS/$THEADS$([ "$DRY" = 1 ] && echo " dry=1")" >> "$LOG"
command -v gh_auth_reset >/dev/null 2>&1 && gh_auth_reset
command -v gh_repo_token_reset >/dev/null 2>&1 && gh_repo_token_reset
exit 0
