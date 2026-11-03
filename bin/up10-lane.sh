#!/bin/bash
# bin/up10-lane.sh — run self-improvement ("up10") work on the box that OWNS
# cromford, never on the hub.
#
# usage: up10-lane.sh <slug> <brief-file>          from anywhere (the hub's
#                                                  orchestrator turn included)
#        up10-lane.sh --here <slug> <brief-file>   the ssh hop's target side
#
# WHY THIS FILE EXISTS. Until 2026-09-15 the up10 chain was an orchestrator
# session on the hub running `git worktree add` into /root/harness/tmp/wt-up10-*
# and driving agent-call.sh by hand. Ten of those lanes were mid-flight when the
# hub's /root/harness was wiped. Worse, the PRs they produced (#379, #380, #381)
# had no ai-build issue, no build dir and no queue row behind them, so triage
# logged all three as orphans and nothing could tell what they were for.
#
# So the on-box semantics here are the ORDINARY PIPELINE, not a bespoke lane:
# file (or find) an `ai-build` issue titled `up10: <slug>`, then launch
# bin/run-build.sh against it exactly the way prompts/cromford.md says to.
# That buys claims, the review lenses, CI and a RESULT for free, and the issue
# title is a real dedupe key an operator can look at.
#
# The hop's remote command mints its own GH_TOKEN and sets its own PATH on the
# target box, because a BatchMode ssh session carries neither.
#
# Env: UP10_SSH   the ssh command (default `ssh -o BatchMode=yes -o ConnectTimeout=15`)
# Exit: 0 launched (or the remote's rc), 2 fail-closed, 77 refused on the hub.
set -uo pipefail
HARNESS="${HARNESS:-/root/harness}"
# BH-4080: HARNESS_HUB_BOX, the hub's fleet name when HUB_BOX_NAME is unset.
# shellcheck source=bin/lib/deployment.sh
. "${HARNESS_DEPLOYMENT_FILE-$(dirname "${BASH_SOURCE[0]}")/lib/deployment.sh}" || exit 1
PROJECT=cromford
ALERTS="$HARNESS/logs/ALERTS.log"
LOG="$HARNESS/logs/up10.log"
STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
mkdir -p "$HARNESS/logs" 2>/dev/null

HERE=0
if [ "${1:-}" = "--here" ]; then HERE=1; shift; fi
SLUG=$(printf %s "${1:-}" | tr -dc 'A-Za-z0-9._-' | cut -c1-64)
BRIEF="${2:-}"

# FAIL CLOSED, LOUDLY. Every stop in this script is one ALERTS line naming what
# is missing and rc 2 — an empty ssh target is `root@`, which hangs rather than
# errors, and a hang is indistinguishable from silence.
die() {
  echo "$(STAMP) [up10] $*" >> "$ALERTS"
  echo "up10-lane: $*" >&2
  exit 2
}
[ -n "$SLUG" ] || die "usage: up10-lane.sh [--here] <slug> <brief-file> — the slug is empty after cleaning to [A-Za-z0-9._-]"
[ -n "$BRIEF" ] && [ -r "$BRIEF" ] && [ -s "$BRIEF" ] \
  || die "brief file '${BRIEF:-<none>}' is missing, unreadable or empty (slug $SLUG) — nothing to build from"

# Same sibling-first / deployed-path / no-op chain as the three guards
# (bin/lib/hub-box.sh). The no-op fallbacks here are NOT fail-open: up10 on the
# hub is the exact thing this file exists to stop, so a box without the lib
# still refuses, it just writes the line itself.
# shellcheck source=bin/lib/hub-box.sh
for _hb in "$(dirname "$0")/lib/hub-box.sh" "$HARNESS/bin/lib/hub-box.sh"; do
  [ -r "$_hb" ] && { . "$_hb"; break; }
done
# BH-1651: the dedupe read is REST. gh-rest-list.sh sources gh-rest.sh.
for _gr in "$(dirname "$0")/lib/gh-rest-list.sh" "$HARNESS/bin/lib/gh-rest-list.sh"; do
  # shellcheck source=bin/lib/gh-rest-list.sh
  [ -r "$_gr" ] && { . "$_gr"; break; }
done
# BH-8962: the ticket is filed over REST, never `gh issue create` (GraphQL).
for _gr in "$(dirname "$0")/lib/tracker/gh-issue-create.sh" "$HARNESS/bin/lib/tracker/gh-issue-create.sh"; do
  # shellcheck source=bin/lib/tracker/gh-issue-create.sh
  [ -r "$_gr" ] && { . "$_gr"; break; }
done
command -v local_box_name >/dev/null 2>&1 || local_box_name() {
  cat "$HARNESS/state/box-name" 2>/dev/null || printf %s "${BOX_NAME:-}"
}
command -v is_hub_box >/dev/null 2>&1 || is_hub_box() {
  # Same three aliases the lib knows (local, the default fleet name, and an
  # operator's HUB_BOX_NAME). A fallback that knows fewer names than the lib is
  # a fallback that lets the hub through under whichever name it is missing.
  case "${1:-}" in
    '')                  return 1 ;;
    local|"$HARNESS_HUB_BOX") return 0 ;;
    *) [ "${1:-}" = "${HUB_BOX_NAME:-}" ] ;;
  esac
}
command -v hub_no_build_up10_refuse >/dev/null 2>&1 || hub_no_build_up10_refuse() {
  echo "$(STAMP) [hub-no-build] refused up10 ${1:-unknown} on $(local_box_name) — the hub runs no agent build work (docs/HUB-THINNING-PLAN.md)" >> "$ALERTS"
  return 0
}
LOCAL=$(local_box_name)

# up10_here — the target side: the ordinary pipeline, on this box.
up10_here() {
  local repo n= rb lt lrc=0 ue
  repo=$("$HARNESS/bin/fleet-conf.sh" "$PROJECT" repo 2>/dev/null || true)
  [ -n "$repo" ] || die "fleet.conf has no repo for $PROJECT — cannot file the ai-build issue for up10: $SLUG"
  # DEDUPE BEFORE CREATE (never a second issue for the same slug). The title is
  # the natural key and it is a real record, not a local flag file.
  #
  # A FAILED READ IS NOT "NO ISSUE". If gh cannot answer — rate limit, token,
  # network — an empty answer looks exactly like "nothing open with that title",
  # and the next line would file a duplicate every time it was retried. So the
  # read's exit code is checked and a failure stops here.
  lt=$(mktemp) || die "no temp file for the up10: $SLUG dedupe read"
  gh_rest_issue_list "$repo" open ai-build 1000 > "$lt" || lrc=$?
  if [ "$lrc" -eq 0 ]; then
    n=$(jq -r --arg t "up10: $SLUG" '.[]|select(.title==$t)|.number' "$lt" | head -1 | tr -dc '0-9') || lrc=$?
  fi
  rm -f "$lt"
  [ "$lrc" -eq 0 ] || die "gh issue list failed (rc $lrc) for up10: $SLUG — refusing to file a duplicate on a read that did not answer"
  if [ -z "$n" ]; then
    command -v gh_issue_create >/dev/null 2>&1 \
      || die "gh issue create failed for up10: $SLUG — bin/lib/tracker/gh-issue-create.sh not loaded"
    ue=$(mktemp) || die "no temp file for the up10: $SLUG create"
    if ! gh_issue_create "$repo" "up10: $SLUG" "$BRIEF" ai-build > /dev/null 2> "$ue"; then
      lt=$(tail -1 "$ue"); rm -f "$ue"
      die "gh issue create failed for up10: $SLUG — $lt"
    fi
    n=$GH_ISSUE_NUMBER
    [ -n "$n" ] || die "gh issue create printed no issue number for up10: $SLUG — $(tail -1 "$ue")"
    rm -f "$ue"
  fi
  rb="$HARNESS/bin/run-build.sh"
  [ -x "$rb" ] || die "no $rb on $LOCAL — the box that owns $PROJECT has no harness to build with"
  # The launch command from prompts/cromford.md, verbatim in shape.
  setsid "$rb" "$PROJECT" "$n" "BH-$n" > "$HARNESS/logs/$PROJECT.bh-$n-build.out" 2>&1 &
  echo "$(STAMP) [up10] $SLUG launched BH-$n on ${LOCAL:-this box}" >> "$LOG"
  # STARTED, and it says so. The PR is the BUILT proof, and it lands in the
  # build record like every other ticket's does.
  echo "LAUNCHED BH-$n (up10: $SLUG) on ${LOCAL:-this box} — expected-by +90m; result lands in builds/$PROJECT-BH-$n-*/RESULT"
}

# --- the hub never runs the local path, override or no override --------------
if [ "$HERE" = 1 ]; then
  if is_hub_box "$LOCAL"; then
    hub_no_build_up10_refuse "$SLUG"
    echo "$(STAMP) [up10] $SLUG refused on $LOCAL — the hub runs no agent build work" >> "$LOG"
    exit 77
  fi
  up10_here
  exit $?
fi

# --- from anywhere: resolve the owning box and hop -----------------------------
TARGET=$("$HARNESS/bin/box-for.sh" "$PROJECT" 2>/dev/null || true)
case "$TARGET" in
  '')      die "no owning box for $PROJECT — fleet.conf column 6 is unset, so there is nowhere to send up10: $SLUG" ;;
  local)   die "fleet.conf says $PROJECT is owned by 'local' (the hub) — the hub runs no agent build work; give $PROJECT a real box before running up10: $SLUG" ;;
esac
# ...and 'local' is only ONE of the hub's names. If column 6 names the hub by
# its fleet name (box-hub, or whatever HUB_BOX_NAME says), the owner
# and the local box match on the hub and the shortcut below would run the local
# path there — the exact thing this file exists to stop. Refuse by identity,
# not by spelling, and refuse from every box: hopping to the hub only moves the
# refusal to the far side of an ssh.
if is_hub_box "$TARGET"; then
  die "fleet.conf says $PROJECT is owned by the hub ($TARGET) — the hub runs no agent build work; give $PROJECT a real box before running up10: $SLUG"
fi
if [ -n "$LOCAL" ] && [ "$LOCAL" = "$TARGET" ]; then
  up10_here
  exit $?
fi
IP=$("$HARNESS/bin/fleet-conf.sh" --tailnet-ip-of-box "$TARGET" 2>/dev/null || true)
[ -n "$IP" ] || die "no tailnet address for $TARGET in fleet.conf — 'root@' is a hang, not an error, so up10: $SLUG stops here"
REPO=$("$HARNESS/bin/fleet-conf.sh" "$PROJECT" repo 2>/dev/null || true)
[ -n "$REPO" ] || die "fleet.conf has no repo for $PROJECT — the far side cannot mint a GitHub token for up10: $SLUG"
RBRIEF="/root/harness/tmp/up10-$SLUG.brief"
# THE FAR SIDE MINTS ITS OWN TOKEN AND SETS ITS OWN PATH. A BatchMode ssh
# carries neither — no GH_TOKEN, and a stripped environment — so the far side's
# dedupe read (`gh issue list` above) had no credential and fail-closed on
# every launch (BH-639). The mint is written `\$(` so it is evaluated on the
# TARGET shell, never here: the token is created on the box that uses it, never
# crosses the wire, and never appears in either side's process listing.
RCMD="export PATH=\"\${PATH:+\$PATH:}/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\"; \
GH_TOKEN=\$(/root/harness/bin/gh-token.sh $REPO); export GH_TOKEN; \
mkdir -p /root/harness/tmp && cat > $RBRIEF && /root/harness/bin/up10-lane.sh --here $SLUG $RBRIEF"
# shellcheck disable=SC2086  # UP10_SSH is a command + flags by design
${UP10_SSH:-ssh -o BatchMode=yes -o ConnectTimeout=15} "root@$IP" "$RCMD" < "$BRIEF"
RC=$?
echo "$(STAMP) [up10] $SLUG -> $TARGET ($IP) rc=$RC" >> "$LOG"
exit $RC
