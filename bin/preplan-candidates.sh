#!/bin/bash
# bin/preplan-candidates.sh <project>  — stdout: TSV "KEY<TAB>TICKET_ID<TAB>REASON"
#
# WHAT AND WHY (the operator, 2026-09-14). Tonight's measured pipeline is 60-75 min per
# ticket, of which PLAN is 7-10. Those ten minutes are pure latency for a ticket
# we already KNOW is coming: a child whose parent PR is open will be buildable
# the moment that PR lands, and the next two ready tickets on a board will be
# picked up by the triage tick 20 minutes from now whatever we do. A plan is
# read-only and costs $1-2, so planning them early is the cheapest ten minutes
# on the board — as long as something deterministic decides WHICH tickets, and
# that is this script. It never launches anything.
#
# IT WRITES EXACTLY ONE THING (BH-499, 2026-09-16), and the exception is named
# here rather than discovered at the bottom of the file: with
# PREPLAN_SPECULATIVE=0 it runs bin/planned-files-cheap.sh for its own `child`
# and `blocked` rows. Those rows are otherwise printed and then ignored — the
# legacy tick takes the first `queued` one and nothing else — so the evidence
# bin/dep-verify.sh reads never gets written and every Blocked-by line goes back
# to being obeyed. The bodies are already in hand from the `gh issue list`
# below, so it costs no extra request. See the block at the end of the
# GitHub-Issues lane.
#
# Three classes, printed in this order (the caller takes them in order):
#   queued  the READY-QUEUE.log lines for this project — 2026-07-23 behaviour,
#           kept at the head of the list so the ticket about to build wins.
#   child   blocked by a parent that is ALREADY CLEARING: the parent is closed
#           (merged, child not yet picked up), its PR is open, or — since
#           2026-09-16 — it is MID-BUILD. Nothing here depends on the
#           STACKABLE-parent work a sibling lane is adding — an open parent PR is
#           a fact GitHub already reports.
#
#           MID-BUILD IS THE EARLIEST HONEST SIGNAL, and until today it was the
#           missing one. A parent's build runs 45-70 minutes on project-5 before
#           its PR exists; for that whole hour the parent is neither closed nor
#           claimed, so its children read here as children of work nobody had
#           started and fell to the `blocked` class — bounded by PREPLAN_AHEAD
#           and last in the cap, so in a real wave most of them were never
#           planned at all. That is exactly the hour bin/dep-verify.sh needs:
#           its file half reads the CHILD's planned-files list, a child with no
#           pre-plan is UNKNOWN, and UNKNOWN is obeyed like a hard blocker — so
#           a sibling that shares no file with its parent sat out the parent's
#           entire build for want of a $1-2 read-only plan.
#           preplan_midbuild_keys is the signal (build dir with no RESULT, a
#           held build-key lock, a `running` build row in the jobs ledger), and
#           the class is printed `child-building` so the tick's log says which
#           fact released it.
#   ahead   the first PREPLAN_AHEAD_READY untouched ready tickets, oldest
#           first. With bin/overlap-schedule.sh on (the default) that number
#           defaults to 10 rather than PREPLAN_AHEAD's 2 — it is the input to
#           the overlap graph, and a graph over 2 of 30 ready tickets cannot say
#           which ones are independent — but an EXPLICIT PREPLAN_AHEAD still
#           wins, because a box that set it is controlling spend and every
#           pre-plan is a paid session. OVERLAP_SCHEDULE=0 puts the class back
#           to PREPLAN_AHEAD outright. Either way the per-tick SPEND is bounded
#           where it always was, by PREPLAN_PARALLEL in bin/preplan-tick.sh:
#           more candidates means more ticks, not more sessions in one tick.
#   blocked (W2-G, 2026-09-14) a child whose blockers are STILL OPEN and not even
#           started. Until tonight that was the one class deliberately excluded,
#           on the reasoning that a parent whose shape is unknown makes its
#           child's plan a guess. bin/dep-verify.sh changes what the plan is FOR:
#           the child's planned-files list is now the evidence that decides
#           whether the Blocked-by line is a real code dependency or an ordering
#           preference somebody typed once, and that evidence has to exist
#           BEFORE the parent lands or the verdict is UNKNOWN and the wave stays
#           as narrow as it is today. Planned against main, like every other
#           class, and LAST — it is the most speculative thing on the list, so
#           when PREPLAN_PARALLEL bites it is the first to be dropped. Bounded by
#           PREPLAN_AHEAD, which `ahead` reads only when it is set explicitly
#           (see above). GitHub-Issues lanes only:
#           dep-verify reads Blocked-by lines, which in-app boards do not have,
#           so a blocked board child's plan would have no consumer.
#           DEP_VERIFY=0 / flags/dep-verify-off removes the class entirely and
#           this script is byte for byte what it was before W2-G.
#
# GitHub-Issues projects (fleet.conf board prefix "-") read the same
# `gh issue list --label ai-build --state all` call bin/unblocked-children.sh
# makes, with the same Blocked-by line regex — one parser for "who blocks whom",
# because two that disagree is a child launched under a live blocker. In-app
# boards get the SAME line regex over the ticket description, widened only to
# accept a board KEY (TK-64) beside a #N, because a board has no issue numbers.
#
# FAIL-OPEN EVERYWHERE: any failure prints what it has and exits 0. This is an
# optimisation; a dead token must cost a pre-plan, never a tick.
#
# FAIL-OPEN IS NOT FAIL-BLIND (BH-782). "Prints what it has" used to include a
# GitHub read that FAILED: `PRS=$(gh pr list …); [ -n "$PRS" ] || PRS='[]'`
# turned an outage into the fact "no PR carries this ticket", and every child
# was then offered as a candidate on top of work already written (#768). The two
# GitHub reads below go through bin/lib/gh-rest.sh, and a non-200 takes the
# gate_unknown arm: the READY-QUEUE lines still flow — GitHub has no say in
# those — NO candidate row is printed, the status is logged, and the exit is
# still 0 because a tick must not die for an optimisation lane.
#
# gh-rest: no-graphql
set -uo pipefail
PROJECT="${1:?usage: preplan-candidates.sh <project>}"
HARNESS="${HARNESS:-/root/harness}"
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=bin/lib/preplan-lib.sh
[ -r "$HERE/lib/preplan-lib.sh" ] && . "$HERE/lib/preplan-lib.sh"
command -v preplan_ahead >/dev/null 2>&1 || preplan_ahead() { echo 2; }
command -v preplan_ahead_ready >/dev/null 2>&1 || preplan_ahead_ready() { preplan_ahead "$@"; }
# TWO BOUNDS (BH-475). `ahead` is the READY backlog, and with
# bin/overlap-schedule.sh on it follows PREPLAN_AHEAD_READY (default 10, or an
# explicitly set PREPLAN_AHEAD) — the graph it feeds can only schedule tickets
# it has a file list for, and the per-tick spend stays capped by
# PREPLAN_PARALLEL in bin/preplan-tick.sh. `blocked` keeps PREPLAN_AHEAD: a
# child of a parent nobody has started is not ready, and it is the class the cap
# is meant to drop first.
AHEAD=$(preplan_ahead_ready "$HARNESS")
BAHEAD=$(preplan_ahead "$HARNESS")
# The `blocked` class's switch is the dep-verify kill flag, read from the one
# lib three callers share. An absent lib is the flag being off.
DEP_OK=0
# shellcheck source=bin/lib/dep-verify-lib.sh
[ -r "$HERE/lib/dep-verify-lib.sh" ] && . "$HERE/lib/dep-verify-lib.sh" 2>/dev/null
command -v dep_verify_on >/dev/null 2>&1 && DEP_OK=$(dep_verify_on "$HARNESS")
# The hotfix lane's kill flag and label name, from the one lib every caller
# reads (#368). An absent lib is the lane being off, and this script is then
# byte for byte what it was before #368.
HOTFIX_ON=0
# shellcheck source=bin/lib/hotfix-lib.sh
[ -r "$HERE/lib/hotfix-lib.sh" ] && . "$HERE/lib/hotfix-lib.sh" 2>/dev/null
command -v hotfix_lane_on >/dev/null 2>&1 && HOTFIX_ON=$(hotfix_lane_on "$HARNESS")
HOTFIX_LABEL_NAME=hotfix
command -v hotfix_label >/dev/null 2>&1 && HOTFIX_LABEL_NAME=$(hotfix_label "$HARNESS")
# The App-token helper for the GitHub-Issues lane below; absent lib = no arm.
# shellcheck source=bin/lib/gh-app-auth.sh
[ -r "$HERE/lib/gh-app-auth.sh" ] && . "$HERE/lib/gh-app-auth.sh" 2>/dev/null
# The REST contract (#780). An absent lib is handled at the call site by
# gate_unknown, not by falling through to a GraphQL read.
# shellcheck source=bin/lib/gh-rest.sh
[ -r "$HERE/lib/gh-rest.sh" ] && . "$HERE/lib/gh-rest.sh" 2>/dev/null
# THE KEYS THE PRE-PLAN LEDGER HAS SETTLED (BH-475 review). A key whose pre-plan
# session already ran and produced nothing — `empty`, or `failed` at the cap —
# is dropped from the SPECULATIVE classes (`ahead`, `blocked`), because a row
# nobody may buy still spends one of the PREPLAN_AHEAD_READY slots and starves
# the next ticket of a plan. Queued, child and hotfix rows STAY: those are the
# tickets the fleet is actively trying to build, bin/overlap-schedule.sh needs
# them in the candidate set to place them at all, and bin/preplan-tick.sh's own
# guard is what stops them costing a session.
TERMINAL=""
if command -v preplan_terminal >/dev/null 2>&1; then
  for _D in "$HARNESS/plans/$PROJECT-"*; do
    [ -d "$_D" ] || continue
    _K=$(basename "$_D"); _K="${_K#"$PROJECT-"}"
    [ -n "$_K" ] || continue
    preplan_terminal "$HARNESS" "$PROJECT" "$_K" >/dev/null 2>&1 && TERMINAL="$TERMINAL $_K"
  done
fi
Q="$HARNESS/logs/READY-QUEUE.log"
# THE READY SET (BH-1033): the file's lines UNION the `ready` build_queue rows,
# with one definition for every lane. Flag off, lib absent, worker unreachable —
# each degrades to the grep of $Q this script has always run.
# shellcheck source=bin/lib/ready-queue.sh
[ -r "$HERE/lib/ready-queue.sh" ] && . "$HERE/lib/ready-queue.sh" 2>/dev/null
command -v rq_lines >/dev/null 2>&1 || rq_lines() { grep -E '^[A-Z]+-[0-9]' "$Q" 2>/dev/null; }

# THE QUEUE LINES ARE BUFFERED, NOT PRINTED (#368). They still come out ahead
# of every speculative class, exactly as they have since 2026-07-23 — but a
# hotfix sorts ahead of EVERYTHING, and the GitHub lane below is the only code
# that knows which issue carries the label. So the lines are written here and
# emitted by whoever learns that: the GitHub lane hands the file to Python, and
# every other path calls emit_queued before it leaves. The trap is on the next
# line and not further down, because the two checks between here and the first
# exit are exactly the ones that would otherwise leak this file on every tick.
QF=$(mktemp)
GF=$(mktemp)
trap 'rm -f "$QF" "$GF"' EXIT
emit_queued() { cat "$QF" 2>/dev/null; : > "$QF"; }

# THE LAUNCH GATE'S ONE HONEST ANSWER (BH-782). A GitHub read we could not make
# tells us nothing about which tickets are already carried by a PR, so this tick
# offers NO candidates — the queued lines still go out, the status goes in the
# project log where the tick's other reasons already are, and the exit is 0.
# The status words come from bin/lib/gh-rest.sh's classification and nothing is
# invented: a bare 403 logs `HTTP 403` with no reason after it.
#
# THE ARGUMENT EXISTS FOR THE 2xx HALF OF THE RULE. `gh_rest` answers 0 for any
# non-empty 2xx body, so a 200 carrying a proxy page, a truncated response or an
# error object reaches the jq below and fails there — a read we could not USE,
# which the ticket's rule puts in the same class as a non-200 ("a non-200, or a
# 2xx with an unusable body, is UNKNOWN"). Those arms pass their own reason so
# the log line does not read `HTTP 200` with nothing to explain it.
gate_unknown() { # gate_unknown [reason]; default: the classified HTTP status
  local why="${1:-}"
  [ -n "$why" ] || why="HTTP ${GH_REST_STATUS:-000}${GH_REST_REASON:+ $GH_REST_REASON}"
  mkdir -p "$HARNESS/logs" 2>/dev/null
  printf '%s [%s] preplan: launch gate UNKNOWN (%s) — no candidates this tick\n' \
    "$(date -u '+%Y-%m-%d %H:%M:%SZ')" "$PROJECT" "$why" \
    >> "$HARNESS/logs/$PROJECT.log" 2>/dev/null || true
  emit_queued
  exit 0
}

# ---- 1. queued -------------------------------------------------------------
# The queue line shape bin/preplan-tick.sh has always read:
#   "<KEY> <ticket-id> — ... project=<repo> ..."
# project= is preferred and bin/project-of.sh is the fallback, exactly as the
# tick does it — a queue line for a newer project matched nothing before that
# fallback existed and its ticket was simply never pre-planned.
while IFS= read -r line; do
  key=$(printf '%s' "$line" | grep -oE '^[A-Z]+-[0-9A-Za-z]+') || continue
  [ -n "$key" ] || continue
  tid=$(printf '%s' "$line" | awk '{print $2}')
  proj=$(printf '%s' "$line" | grep -oE 'project=[a-z-]+' | cut -d= -f2)
  [ -n "$proj" ] || proj=$("$HERE/project-of.sh" "$line" 2>/dev/null || echo "")
  [ "$proj" = "$PROJECT" ] || continue
  printf '%s\t%s\tqueued\n' "$key" "${tid:--}" >> "$QF"
done < <(rq_lines "$HARNESS" "$PROJECT" 2>/dev/null)

BP=$("$HERE/fleet-conf.sh" "$PROJECT" board_prefix 2>/dev/null || true)
# Jira and Linear (BH-8451): column 4 says `-` for them too, so the GitHub lane
# below would offer the code repo's issues as their tickets. They take the
# board lane's matcher instead, fed from the tracker contract (bin/lib/trk-lane.sh).
TRK_LANE_KIND=""
# shellcheck source=bin/lib/trk-lane.sh
[ -r "$HERE/lib/trk-lane.sh" ] && . "$HERE/lib/trk-lane.sh" 2>/dev/null && trk_lane_kind "$HARNESS" "$PROJECT"
case "$TRK_LANE_KIND" in jira|linear) ;; *) TRK_LANE_KIND="" ;; esac

# ---- 2+3. GitHub-Issues lane ------------------------------------------------
if [ "$BP" = "-" ] && [ -z "$TRK_LANE_KIND" ]; then
  REPO="${GH_ISSUES_REPO:-$("$HERE/fleet-conf.sh" "$PROJECT" repo 2>/dev/null || true)}"
  [ -n "$REPO" ] || { emit_queued; exit 0; }
  # The KEY the builder will ask for is <PREFIX>-<issue-number>; without the
  # prefix a pre-plan would be filed under a name nothing ever looks up.
  PFX=$(preplan_key_prefix "$HARNESS" "$PROJECT" 2>/dev/null) || { emit_queued; exit 0; }
  [ -n "$PFX" ] || { emit_queued; exit 0; }
  command -v gh_auth_for >/dev/null 2>&1 && gh_auth_for "$REPO" || true
  # A box whose sync has not landed the contract lib cannot ask the question at
  # all, which is the same CLASS of answer as a 403 — but it is not an HTTP
  # anything, and gate_unknown's default reason would print "HTTP 000" and send
  # an operator hunting a network fault that never happened.
  command -v gh_rest >/dev/null 2>&1 \
    || gate_unknown "bin/lib/gh-rest.sh (the REST contract) is not readable on this box"
  # The raw `gh_rest GET` below interpolates $REPO into the API path itself, so
  # it does not get the shape check every gh_rest_* helper performs for free.
  # $REPO is operator-controlled (fleet.conf / GH_ISSUES_REPO), so this is a
  # guard on a path sink rather than a live injection — but a typo that admits
  # `owner/../other` would silently point this gate at another resource.
  if command -v _gh_rest_args_ok >/dev/null 2>&1; then
    _gh_rest_args_ok "$REPO" || gate_unknown "bad repo slug in fleet.conf/GH_ISSUES_REPO"
  fi
  # `labels` joins the field list for #368: it is what says which of these
  # issues is the emergency one. One extra field on a call that is already
  # made, never a second call.
  #
  # THE BODY GOES TO A FILE, NOT A `$( )`. GH_REST_STATUS is set in the shell
  # that CALLS the helper, and a command substitution takes the status to the
  # grave (bin/lib/gh-rest.sh's header says so in as many words) — gate_unknown
  # would then log HTTP 000 for a 403 the library classified correctly.
  gh_rest GET "repos/$REPO/issues" -f labels=ai-build -f state=all -F per_page=100 \
    > "$GF" || gate_unknown
  # REST /issues RETURNS PULL REQUESTS; `gh issue list` filtered them. Without
  # the select() a PR numbered N reads as an open issue and gets planned.
  # `state` stays lowercase from REST — the Python matcher upper-cases it.
  # A 2xx body this jq cannot read is a read we could not USE — same arm, same
  # log line, because "no candidates and no reason written down" is the shape
  # the fleet rule calls a whisper.
  ISSUES=$(jq -c '[.[] | select(.pull_request == null)
                   | {number, state, title, body, labels: [(.labels // [])[] | {name}]}]' "$GF" 2>/dev/null) \
    || gate_unknown "HTTP ${GH_REST_STATUS:-000} (the issue list body would not parse)"
  [ -n "$ISSUES" ] || gate_unknown "HTTP ${GH_REST_STATUS:-000} (the issue list body would not parse)"
  # Token discipline (fleet rule): the four fields the matcher needs, never a
  # default human dump of 50 PRs. A failure here is the DEFECT THIS TICKET IS
  # ABOUT: `[ -n "$PRS" ] || PRS='[]'` said "no PR carries this ticket" on every
  # outage, and every child was offered on top of work already written.
  # ...and that defect is not only about the rc. A 2xx body the jq below cannot
  # read used to land in the very same `PRS='[]'`, which is why BOTH halves go
  # to gate_unknown: the launch gate has one honest answer for "we could not
  # read it", whether the read failed at the status line or at the body.
  gh_rest_pr_list "$REPO" open "" 100 > "$GF" || gate_unknown
  PRS=$(jq -c '[.[] | {number, title, headRefName: .head.ref, body}]' "$GF" 2>/dev/null) \
    || gate_unknown "HTTP ${GH_REST_STATUS:-000} (the PR list body would not parse)"
  [ -n "$PRS" ] || gate_unknown "HTTP ${GH_REST_STATUS:-000} (the PR list body would not parse)"
  # The tickets this fleet is BUILDING right now, as issue numbers. The keys come
  # back as <PFX>-<issue>, and anything that does not have this project's prefix
  # (a stray directory, another project's lock) is dropped rather than guessed at.
  MIDBUILD=""
  if command -v preplan_midbuild_keys >/dev/null 2>&1; then
    MIDBUILD=$(preplan_midbuild_keys "$HARNESS" "$PROJECT" 2>/dev/null \
               | sed -n "s/^$PFX-\([0-9][0-9]*\)$/\1/p" | tr '\n' ' ')
  fi
  IF=$(mktemp); PF=$(mktemp); RF=$(mktemp); trap 'rm -f "$IF" "$PF" "$RF" "$QF" "$GF"' EXIT
  printf '%s' "$ISSUES" > "$IF"; printf '%s' "$PRS" > "$PF"
  # The queue file is an ARGUMENT, not a pipe: Python has to interleave those
  # lines with its own rows (a queued hotfix moves to the front), and a crash
  # mid-render must leave the queue unspent so the fallback below can emit it
  # exactly as this script did before #368.
  if ! AHEAD="$AHEAD" BAHEAD="$BAHEAD" PFX="$PFX" DEP_OK="$DEP_OK" MIDBUILD="$MIDBUILD" \
       TERMINAL="$TERMINAL" \
       HOTFIX_ON="$HOTFIX_ON" HOTFIX_LABEL_NAME="$HOTFIX_LABEL_NAME" \
       HARNESS="$HARNESS" PROJECT="$PROJECT" \
       python3 - "$IF" "$PF" "$QF" > "$RF" 2>/dev/null <<'PYEOF'
import datetime, json, os, re, sys

def load(p):
    try:
        with open(p) as f: return json.load(f)
    except Exception: return []

issues, prs = load(sys.argv[1]), load(sys.argv[2])
ahead = int(os.environ.get("AHEAD") or 0)
bahead = int(os.environ.get("BAHEAD") or 0)
dep_ok = os.environ.get("DEP_OK") == "1"
# Keys whose pre-plan ledger is terminal — see the shell block that builds this.
terminal = set((os.environ.get("TERMINAL") or "").split())

# --- the hotfix class (#368) -------------------------------------------------
# One label makes a ticket the emergency one, and this is the only place in the
# pre-plan lane that can see it. The match is EXACT and whole-name (the same
# rule bin/lib/hotfix-lib.sh applies, and for the same reason: a substring
# match reads `hotfix-candidate` and `not-hotfix` as emergencies). A gh call
# that returned no `labels` key — which is every fixture and every caller from
# before this change — is simply not a hotfix.
hot_on = os.environ.get("HOTFIX_ON") == "1"
hot_label = (os.environ.get("HOTFIX_LABEL_NAME") or "hotfix").strip().lower()

def is_hot(i):
    if not hot_on or not isinstance(i, dict):
        return False
    for l in (i.get("labels") or []):
        name = l.get("name") if isinstance(l, dict) else l
        if str(name or "").strip().lower() == hot_label:
            return True
    return False

# The SAME two regexes bin/unblocked-children.sh uses. Copied deliberately and
# named as such: they are the fleet's definition of a blocker line, and the day
# they drift is the day a child is planned under a live blocker.
line_re = re.compile(r"^[\s>*_\-#]*blocked[- ]by\b(.*)$", re.IGNORECASE | re.MULTILINE)
num_re = re.compile(r"#(\d+)")

state = {int(i["number"]): str(i.get("state", "")).upper()
         for i in issues if isinstance(i, dict) and "number" in i}

# The issues a build is running on RIGHT NOW (preplan_midbuild_keys). A parent
# in here is clearing just as surely as one with an open PR — earlier, in fact,
# because the PR is what the build is on its way to producing.
midbuild = set()
for tok in (os.environ.get("MIDBUILD") or "").split():
    try: midbuild.add(int(tok))
    except ValueError: pass

# An issue number a PR CLAIMS: its head branch, title or body naming #N or the
# ticket key. Same boundary rule the snapshot lane uses — #24 must not claim 249.
claimed = set()
for pr in prs:
    if not isinstance(pr, dict): continue
    hay = " ".join(str(pr.get(k) or "") for k in ("title", "headRefName", "body"))
    for n in num_re.findall(hay):
        claimed.add(int(n))
    for m in re.findall(r"(?<![A-Za-z0-9])[A-Za-z]{1,6}-(\d+)(?![0-9])", hay):
        claimed.add(int(m))

# `Needs: #n` is the other spelling of a HARD blocker the harness skill
# documents, and it is read HERE for hotfix rows only. Plain issues keep exactly
# today's parse (Blocked-by alone), because widening the blocker grammar for
# everybody would newly hold children that have been building for weeks. On a
# hotfix it has to bite: the label is the reason somebody in a hurry reaches
# for the shorter spelling, and a hotfix that jumps a live blocker is the one
# failure this lane could cause that is worse than being slow.
needs_re = re.compile(r"^[\s>*_\-#]*needs\b(.*)$", re.IGNORECASE | re.MULTILINE)

def blockers(body):
    out = set()
    for m in line_re.finditer(body or ""):
        out.update(int(n) for n in num_re.findall(m.group(1)))
    return out

def hot_blockers(body):
    out = blockers(body)
    for m in needs_re.finditer(body or ""):
        out.update(int(n) for n in num_re.findall(m.group(1)))
    return out

def log_held(n, b):
    """One line in the project log per held hotfix per run (#368 F5).

    A hotfix that is simply absent from the list is indistinguishable from a
    hotfix nobody filed — which is the whole failure this lane exists to stop,
    so the reason is written where the tick's other reasons already are. The
    write is best-effort and cannot change the candidate list: an unwritable
    logs/ directory holds the ticket exactly the same way.
    """
    try:
        live = sorted(x for x in b
                      if not (state.get(x) == "CLOSED" or x in claimed or x in midbuild))
        if not live:
            return
        key = "%s-%s" % (prefix, n)
        # not utcnow(): it is deprecated, and the day it is removed this whole
        # write disappears into the except below without a word.
        stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d %H:%M:%SZ")
        waiting = ", ".join("#%d" % x for x in live)
        path = os.path.join(os.environ.get("HARNESS") or "", "logs",
                            (os.environ.get("PROJECT") or "") + ".log")
        with open(path, "a") as f:
            f.write("%s [%s/%s] hotfix %s not planned: waiting on %s (open, no PR)\n"
                    % (stamp, os.environ.get("PROJECT") or "", key, key, waiting))
    except Exception:
        pass

rows = []
ahead_left = ahead
blocked_left = bahead if dep_ok else 0
prefix = os.environ.get("PFX") or ""
for i in sorted(issues, key=lambda x: int(x.get("number", 0))):
    if not isinstance(i, dict) or "number" not in i: continue
    n = int(i["number"])
    if state.get(n) != "OPEN": continue
    if n in claimed: continue          # a PR already carries this ticket
    if n in midbuild: continue         # its own build is running and writes its own plan
    hot = is_hot(i)
    b = hot_blockers(i.get("body")) if hot else blockers(i.get("body"))
    if b:
        # CLEARING, not cleared: every blocker is either closed already (merged,
        # nobody has picked the child up yet), has an open PR, or is MID-BUILD.
        # A blocker that is open, unclaimed and unbuilt is real work that has not
        # started — planning its child now would plan against a parent whose
        # shape is still unknown.
        if all(state.get(x) == "CLOSED" or x in claimed or x in midbuild for x in b):
            # Which fact released it, in the word the tick logs: a parent whose
            # build is still running is a weaker signal than a parent with a PR,
            # and a log that says "child" for both cannot tell the two apart
            # when one of them turns out to have been wrong.
            why = "child" if all(state.get(x) == "CLOSED" or x in claimed for x in b) else "child-building"
            rows.append((n, why, hot))
        elif hot:
            # A HOTFIX WITH A LIVE BLOCKER IS NOT READY, LABEL OR NO LABEL
            # (#368). The `blocked` class exists to buy dep-verify the evidence
            # that widens a WAVE; a hotfix is one ticket, and its author naming
            # a blocker is the author saying the code it needs has not landed.
            # So it is not emitted at all — neither promoted nor parked at the
            # bottom, where the next reader would find an emergency row sitting
            # under everything and wonder which rule won. The project log is
            # where that decision becomes visible.
            log_held(n, b)
            continue
        elif blocked_left > 0:
            # A parent nobody has started yet. The plan is what bin/dep-verify.sh
            # reads to decide whether this child has to wait at all, so it is
            # worth writing now even though the parent's shape is still unknown:
            # a plan that does not exist is a verdict of UNKNOWN, and UNKNOWN is
            # obeyed exactly like a hard blocker.
            if "%s-%s" % (prefix, n) in terminal: continue
            rows.append((n, "blocked", False)); blocked_left -= 1
        continue
    # A hotfix never spends the PREPLAN_AHEAD budget and is never dropped by it:
    # the cap exists to bound speculation, and an emergency ticket is not a
    # guess about what might be worth planning.
    if hot:
        rows.append((n, "ahead", True))
    elif ahead_left > 0:
        # A terminal key does not even spend the slot: the whole point of the
        # bound is that the ten it buys are ten that can still produce a plan.
        if "%s-%s" % (prefix, n) in terminal: continue
        rows.append((n, "ahead", False)); ahead_left -= 1

# CHILDREN FIRST, then ahead, then blocked. All three are speculative, but a
# child whose parent PR is already open becomes buildable the moment that PR
# lands, while an ahead ticket is waiting on a triage tick up to 20 minutes out
# and a blocked one is waiting on a verdict that may still come back hard — so
# when the PREPLAN_PARALLEL cap bites, the one that pays off soonest is above it
# and the one that may never pay off is at the bottom.
# child-building ranks with child and just under it: both become buildable well
# before an `ahead` ticket's triage tick, and between the two the one whose
# parent already has a PR pays off sooner.
#
# This is the order WITHIN each half. Hotfix rows outrank the class entirely and
# are partitioned off below rather than sorted ahead here — two mechanisms for
# one ordering is how a rule comes to bind somewhere nobody meant. The sort is
# stable, so two hotfixes of one class come out oldest-number first exactly as
# two children do.
ORDER = {"child": 0, "child-building": 1, "ahead": 2, "blocked": 3}
rows.sort(key=lambda r: ORDER.get(r[1], 9))

# The READY-QUEUE lines, which the shell half buffered for us. They have had
# priority since 2026-07-23 and keep it against everything EXCEPT an emergency —
# so a queued line whose issue carries the label moves to the front with the
# other hotfix rows, and the rest stay above the speculative classes where they
# have always been.
qlines = []
if len(sys.argv) > 3:
    try:
        with open(sys.argv[3]) as f:
            qlines = [l.rstrip("\n") for l in f if l.strip()]
    except Exception:
        qlines = []

hot_issue = set()
for i in issues:
    if isinstance(i, dict) and "number" in i and is_hot(i):
        try: hot_issue.add(int(i["number"]))
        except Exception: pass

key_re = re.compile(r"^[A-Za-z]+-(\d+)$")

def qnum(line):
    m = key_re.match(line.split("\t")[0])
    return int(m.group(1)) if m else None

hot_q, plain_q, hot_q_nums = [], [], set()
for l in qlines:
    n = qnum(l)
    if n is not None and n in hot_issue:
        hot_q.append(l); hot_q_nums.add(n)
    else:
        plain_q.append(l)

def fmt(r):
    return "%s-%s\t%s\t%s" % (prefix, r[0], r[0], r[1])

# A hotfix already on the queue is emitted ONCE, from the queue line that names
# the ticket id the tick will build — a second row for the same number would
# spend two pre-plan slots on one ticket.
out = hot_q \
    + [fmt(r) for r in rows if r[2] and r[0] not in hot_q_nums] \
    + plain_q \
    + [fmt(r) for r in rows if not r[2]]
for l in out:
    print(l)
PYEOF
  then
    emit_queued
    exit 0
  fi
  cat "$RF"

  # ---- the cheap file list, when the expensive one is switched off ----------
  # THE ONE WRITE THIS SCRIPT DOES, and it is here because here is the only
  # place that already has the bodies (BH-499).
  #
  # With PREPLAN_SPECULATIVE=0 the tick takes the first `queued` row and nothing
  # else, so every `child` and `blocked` row above is printed and then ignored —
  # no pre-plan, no planned-files list, and bin/dep-verify.sh answers UNKNOWN
  # for all of them, which every caller obeys exactly like HARD. That is the
  # state speculative mode was switched off into on 2026-09-16, and it costs the
  # whole point of dep-verify: a wave runs as wide as its hand-typed Blocked-by
  # graph again.
  #
  # bin/planned-files-cheap.sh is cents, not dollars, and its first two tiers
  # are free — so it runs for those rows anyway. The bodies come from the
  # `gh issue list` above (it already asked for `body`), so the whole pass costs
  # this script ZERO extra GitHub requests, which is what makes it safe to do on
  # every tick.
  #
  # Fail-open like everything else here: detached from the exit path, output
  # discarded, and the rows have already been printed above.
  #
  # `child-building` is in the list for the reason the class exists at all
  # (2026-09-16): its parent's build is running RIGHT NOW, so it is the row whose
  # evidence dep-verify needs soonest, and with speculative mode off it is
  # printed and ignored exactly like `child` and `blocked`.
  if [ "$(preplan_speculative "$HARNESS" 2>/dev/null || echo 1)" = 0 ] \
     && [ -x "$HERE/planned-files-cheap.sh" ]; then
    BD=$(mktemp -d) || BD=""
    if [ -n "$BD" ]; then
      while IFS=$'\t' read -r k n why; do
        case "$why" in child|child-building|blocked) ;; *) continue ;; esac
        [ -n "$k" ] && [ -n "$n" ] || continue
        # The previous child's meta is removed first: $BD is reused for every row,
        # and one leaked `bug` label would silence the next ticket's reroute.
        rm -f "$BD/meta"
        N="$n" python3 - "$IF" "$BD" > "$BD/body" 2>/dev/null <<'PYB' || continue
import json, os, sys
try:
    issues = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(1)
n = int(os.environ["N"])
for i in issues:
    if isinstance(i, dict) and int(i.get("number", -1)) == n:
        sys.stdout.write(i.get("body") or "")
        # The labels the `gh issue list` above ALREADY fetched, in the shape
        # bin/kind-gate.sh reads: it is what tells the cheap pass this is a bug
        # ticket, whose test paths are left alone. Its own try/except because
        # the body is what bin/dep-verify.sh needs — a meta that could not be
        # written costs a kind, never the list.
        try:
            with open(os.path.join(sys.argv[2], "meta"), "w") as fh:
                json.dump({"title": i.get("title") or "", "labels": i.get("labels") or []}, fh)
        except Exception:
            pass
        break
PYB
        [ -s "$BD/body" ] || continue
        PLANNED_FILES_BODY_FILE="$BD/body" PLANNED_FILES_META_FILE="$BD/meta" \
          "$HERE/planned-files-cheap.sh" "$PROJECT" "$k" >/dev/null 2>&1 || true
      done < "$RF"
      rm -rf "$BD"
    fi
  fi
  exit 0
fi

# ---- 2+3. in-app product board (and Jira/Linear, BH-8451) -------------------
# No hotfix class here: the label lives on a GitHub issue and #368 puts a
# board-side priority field out of scope, so the queue lines go out exactly
# where they always did — first, and before any of the checks below can leave.
emit_queued
if [ -n "$TRK_LANE_KIND" ]; then
  # JIRA AND LINEAR: the open build-labelled list, in the board's ticket
  # shape. Status is normalized to the BUSY words (lower case, spaces and `-`
  # to `_`, in_review -> review), so "In Progress" and "In Review" are busy.
  # The list carries no body, so there is no child class. A ticket this box
  # is building now (preplan_midbuild_keys) is dropped. A failed read is the
  # launch gate's UNKNOWN: queued lines only, one log line.
  TF=$(mktemp); trap 'rm -f "$TF" "$QF" "$GF"' EXIT
  trk_lane_list "$HARNESS" "$PROJECT" preplan --state open > "$GF" 2>/dev/null \
    || gate_unknown "$TRK_LANE_KIND list unreadable"
  MIDBUILD=""
  command -v preplan_midbuild_keys >/dev/null 2>&1 \
    && MIDBUILD=$(preplan_midbuild_keys "$HARNESS" "$PROJECT" 2>/dev/null | tr '\n' ' ')
  jq -c --arg mid " $MIDBUILD " '[.[] | select(type == "object" and (.key // "") != "")
      | select(.key as $k | ($mid | index(" " + $k + " ")) == null)
      | {key, id: .key, waitingOn, triageVerdict, body: "",
         status: ((.status // "") | ascii_downcase | gsub("[ -]"; "_") | if . == "in_review" then "review" else . end)}]' \
    "$GF" > "$TF" 2>/dev/null || gate_unknown "$TRK_LANE_KIND list would not parse"
else
BASE=$("$HERE/fleet-conf.sh" "$PROJECT" prod 2>/dev/null || true)
[ -n "$BASE" ] && [ "$BASE" != "-" ] && [ -n "$BP" ] || exit 0
TOK=$("$HERE/internal-token-for.sh" "$PROJECT" 2>/dev/null || true)
[ -n "$TOK" ] || exit 0
BID=$(curl -sf -m 20 -H "Authorization: Bearer $TOK" -H "User-Agent: curl/8" "$BASE$BP/boards" 2>/dev/null \
      | jq -r 'if type=="array" then .[0].id else .boards[0].id end' 2>/dev/null)
[ -n "$BID" ] && [ "$BID" != null ] || exit 0
TF=$(mktemp); trap 'rm -f "$TF" "$QF" "$GF"' EXIT
curl -sf -m 30 -H "Authorization: Bearer $TOK" -H "User-Agent: curl/8" \
  "$BASE$BP/boards/$BID/tickets" 2>/dev/null > "$TF" || exit 0
fi
[ -s "$TF" ] || exit 0
AHEAD="$AHEAD" TERMINAL="$TERMINAL" python3 - "$TF" <<'PYEOF' 2>/dev/null || exit 0
import json, os, re, sys
try:
    with open(sys.argv[1]) as f: raw = json.load(f)
except Exception:
    sys.exit(0)
tickets = raw if isinstance(raw, list) else (raw.get("tickets") or [])
ahead = int(os.environ.get("AHEAD") or 0)
terminal = set(x.upper() for x in (os.environ.get("TERMINAL") or "").split())

line_re = re.compile(r"^[\s>*_\-#]*blocked[- ]by\b(.*)$", re.IGNORECASE | re.MULTILINE)
# A board has no issue numbers, so the TOKEN regex is widened to the board KEY
# spelling beside #N. The LINE regex above is byte-identical to
# bin/unblocked-children.sh's — which line counts as a blocker declaration must
# mean one thing fleet-wide.
tok_re = re.compile(r"#(\d+)|((?<![A-Za-z0-9])[A-Za-z]{1,6}-[0-9]+)")

def field(t, *names):
    for n in names:
        v = t.get(n)
        if v not in (None, ""): return v
    return ""

def key_of(t):
    return str(field(t, "key", "number") or "").strip()

status  = {}
for t in tickets:
    if isinstance(t, dict) and key_of(t):
        status[key_of(t).upper()] = str(field(t, "status") or "").lower()

# DONE-ISH IS THE EXCLUSION LIST, NOT READY-ISH. Four board apps spell their
# columns differently and a positive list would silently drop whichever project
# renamed a column; listing what is FINISHED OR IN FLIGHT is the stable half.
BUSY = {"done", "closed", "cancelled", "canceled", "archived", "review",
        "in_progress", "in-progress", "inprogress", "building", "shipped",
        # paused: nobody builds it until it is un-paused, so it must not hold
        # files ahead of a ready ticket (project-3 TK-147/122/119 vs TK-319, 2026-10).
        "paused"}

def blockers(text):
    out = set()
    for m in line_re.finditer(text or ""):
        for a, b in tok_re.findall(m.group(1)):
            out.add(("#" + a if a else b).upper())
    return out

# NO MID-BUILD CLASS HERE, and none is needed: a board ticket whose build is
# running carries a status this lane already treats as clearing (BUSY holds
# `building`, `in_progress` and `review`), which is the same fact
# preplan_midbuild_keys has to reconstruct from disk on the issues lane because
# a GitHub issue has no such column.
rows, ahead_left = [], ahead
for t in tickets:
    if not isinstance(t, dict): continue
    k = key_of(t)
    if not k: continue
    st = str(field(t, "status") or "").lower()
    if st in BUSY: continue
    # The standing product-board law (~/.claude/CLAUDE.md): needs_clarification
    # with the turn on the client is triage waiting for an answer, and a plan
    # written now would be a guess at the client's intent. an early engagement is
    # the lesson, and it applies to a SPECULATIVE plan exactly as it applies to
    # a build — the plan is what the build executes.
    tv = str(field(t, "triageVerdict", "triage_verdict") or "").lower()
    wo = str(field(t, "waitingOn", "waiting_on") or "").lower()
    # project-3 spells the client's turn "requester" (feature-board waitingOn).
    if tv == "needs_clarification" and wo in ("client", "requester"): continue
    b = blockers(field(t, "description", "body", "content"))
    tid = str(field(t, "id") or "") or k
    if b:
        if all(status.get(x.lstrip("#"), status.get(x, "")) in BUSY for x in b):
            rows.append((k, tid, "child"))
        continue
    if ahead_left > 0:
        # Terminal pre-plan ledger: same rule as the issues lane above.
        if k.upper() in terminal: continue
        rows.append((k, tid, "ahead")); ahead_left -= 1

# Children first — see the GitHub lane above for why the order is the cap's.
rows.sort(key=lambda r: 0 if r[2] == "child" else 1)
for k, tid, why in rows:
    print("%s\t%s\t%s" % (k, tid, why))
PYEOF
command -v gh_auth_reset >/dev/null 2>&1 && gh_auth_reset
exit 0
