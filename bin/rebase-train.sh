#!/bin/bash
# rebase-train.sh <project> — mechanize the DIRTY-PR class the orchestrator
# hand-cleared twice (2026-08-18/19, project-4 #1239/#1250/#1251/#1256 then
# #1253/#1259/#1263/#1267): sibling harness builds all append to the same
# package.json test-script lines, so every merge re-DIRTIES the rest and the
# sweep starves. This train rebases record-backed DIRTY harness PRs onto main,
# union-resolves ONLY the deterministic package.json script-line conflict
# (token union; *.test.tsx / .render. files go to the tsx tail invocation,
# everything else to the first node --test batch), verifies typecheck + unit,
# and force-pushes-with-lease. Any other conflict = skip + one ALERT, human
# judgment stays in the loop. Budget 2 rebases/run (each costs a typecheck).
#
# Rails: only PRs that carry a hub build record with VERDICT: APPROVE and a
# PR_CREATED line naming them (same discovery as merge-sweep); only DIRTY;
# authored by one of HARNESS_PR_AUTHORS; two strikes then park
# (state/rebase-train-skip.txt).
# Kill switch: flags/automerge-disabled stops the train too (a rebase exists
# only to feed the sweep).
#
# SDLC item 1 (head-bound approval): a verified push here also REBINDS the
# approval to the head it produced, on the build record and on the ledger row.
# Without that the sweep — which now refuses a head that is not the reviewed sha
# — would park every PR this train fixes.
# BH-6718: the rebind waits on the BH-5791 caller check of the rebased head.
# Callers found, or a check that could not run, push without a rebind, and
# found callers request a lead review.
set -uo pipefail
PROJECT="${1:?project}"
H="${HARNESS:-/root/harness}"
. "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$H")

# >>> lane gate (BH-1165) — one off-switch and one source of numbers for this
# lane. lane_gate_or_exit exits 0 when flags/all-off, flags/lane-off-rebase-train
# (or its project row) is set; lane_env_apply then puts this
# lane's settings rows into the environment its own ${KNOB:-default} reads use.
# Both fail OPEN: an unreachable worker leaves the lane exactly as it is today.
# Registry: catalog/lanes.json. Operator: bin/harness-ctl.sh off rebase-train <project>.
# shellcheck disable=SC1091
. "${HARNESS:-/root/harness}/bin/lib/lane-gate.sh" 2>/dev/null || true
# The ONE verdict reader (bin/lib/verdict-parse.sh, BH-1625). Missing, every
# verdict reads unknown — never APPROVE.
. "${HARNESS:-/root/harness}/bin/lib/verdict-parse.sh" 2>/dev/null \
  || . "$(dirname "${BASH_SOURCE[0]}")/lib/verdict-parse.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit rebase-train "$PROJECT"
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    rebase-train "$PROJECT"
# For the automerge-disabled read and job_verdict_rebind below. Fail-open like
# every other reader of this client: absent or a dead worker and the train
# behaves exactly as it did.
if [ -f "$H/bin/jobs-client.sh" ]; then # shellcheck source=/dev/null
  . "$H/bin/jobs-client.sh"; fi
REPO="${REPOS_ROOT:-/root/repos}/$PROJECT"
LOG="$H/logs/rebase-train.log"
SKIP="$H/state/rebase-train-skip.txt"; touch "$SKIP"
STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
if command -v flag_active >/dev/null 2>&1; then flag_active automerge-disabled && exit 0
else [ -f "$H/flags/automerge-disabled" ] && exit 0; fi
[ -d "$REPO" ] || exit 0
exec 9>"$H/locks/rebase-train-$PROJECT.lock"; flock -n 9 || exit 0
# >>> BH-1061 wake backstop
if [ -r "$H/bin/lib/wake-lanes.sh" ]; then
  # shellcheck source=bin/lib/wake-lanes.sh
  . "$H/bin/lib/wake-lanes.sh"
fi
if command -v wake_backstop_skip >/dev/null 2>&1 && wake_backstop_skip rebase-train "$PROJECT"; then
  exit 0
fi
# <<< BH-1061 wake backstop
set -a; . "$HENV/global.env" 2>/dev/null; [ -f "$HENV/$PROJECT.env" ] && . "$HENV/$PROJECT.env"; set +a
# AND AGAIN, BELOW THE ENV LOAD (BH-1165 review). `set -a; . env/global.env`
# re-assigns every name it carries, so the call above lost each knob the box's
# env file also sets — the settings row was gone, the page went on reporting
# `source: settings`, and nothing errored: the exact shape this ticket exists to
# end. The call above still earns its place: the knobs this lane reads BEFORE
# this line have no other way to see a row. Applying twice is idempotent (the
# settings cache is already warm) and section 16 of tests/lanes-registry-test.sh
# is the ordering.
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    rebase-train "$PROJECT"
# >>> gh default auth
# THE TRAIN'S GITHUB IDENTITY (BH-470, #424). Every `gh` call this train makes —
# the PR list, the rebase's status reads, the verdict rebind — ran on the fleet
# PAT's one 5000/h bucket; they now run on this project's App installation token.
# Both sources are fail-open and the call is guarded, so a box whose bin/lib/
# predates #469 forks nothing and this train behaves exactly as it does today.
# shellcheck source=bin/lib/gh-app-auth.sh
[ -r "$H/bin/lib/gh-app-auth.sh" ] && . "$H/bin/lib/gh-app-auth.sh"
# shellcheck source=bin/lib/gh-limit-logger.sh
[ -r "$H/bin/lib/gh-limit-logger.sh" ] && . "$H/bin/lib/gh-limit-logger.sh"
if command -v gh_default_auth_for_project >/dev/null 2>&1; then
  gh_default_auth_for_project "$PROJECT" || true
fi
# <<< gh default auth
# WHOSE PRs ARE OURS. The harness author SET (bin/lib/gh-pr-list.sh,
# HARNESS_PR_AUTHORS) — since bin/gh-token.sh went live a harness PR is authored
# by the GitHub App (`app/cromford`) as often as by the PAT, and a
# hardcoded login matches only half of them (2026-09-14, project-5 #696/#697).
# shellcheck source=bin/lib/gh-pr-list.sh
for _P in "$(dirname "$0")/lib/gh-pr-list.sh" "$H/bin/lib/gh-pr-list.sh"; do
  # shellcheck source=/dev/null
  [ -r "$_P" ] && { . "$_P"; break; }
done
# BH-1585: the record's PR is read over REST and a merged one is never read
# again (bin/lib/pr-terminal.sh). Without the lib this lane reads nothing — it
# does not fall back to the `gh pr view` that was ~880 GraphQL calls an hour.
for _P in "$(dirname "$0")/lib/pr-terminal.sh" "$H/bin/lib/pr-terminal.sh"; do
  # shellcheck source=bin/lib/pr-terminal.sh
  [ -r "$_P" ] && { . "$_P"; break; }
done

BASE="${BASE_BRANCH:-main}"

RESOLVER=$(mktemp /tmp/rebase-train-resolver-XXXX.py)
trap 'rm -f "$RESOLVER"' EXIT
cat > "$RESOLVER" <<'PYEOF'
import json, re, sys
s = open('package.json').read()
m = re.search(r'<<<<<<< HEAD\n(.*?)\n=======\n(.*?)\n>>>>>>> [^\n]+\n', s, re.S)
if not m or m.group(1).count('\n') > 0:
    print('NONTRIVIAL'); sys.exit(1)
ours, theirs = m.group(1), m.group(2)
km = re.search(r'"(test:[a-z-]+)":\s*"(.*)",?\s*$', ours)
if not km:
    print('NONTRIVIAL'); sys.exit(1)
key = km.group(1)
def val(line):
    mm = re.search(r'"' + re.escape(key) + r'":\s*"(.*)",?\s*$', line)
    return mm.group(1) if mm else None
o, t = val(ours), val(theirs)
if o is None or t is None:
    print('NONTRIVIAL'); sys.exit(1)
missing = [tok for tok in t.split(' ') if tok not in o.split(' ')
           and tok not in ('&&', 'node', 'npx', 'tsx', '--test')]
parts = o.split(' && ')
for tok in missing:
    if tok.endswith('.test.tsx') or '.render.' in tok:
        parts[-1] += ' ' + tok
    else:
        parts[0] += ' ' + tok
new = ' && '.join(parts)
s = s[:m.start()] + ours.replace(o, new) + '\n' + s[m.end():]
open('package.json', 'w').write(s)
json.load(open('package.json'))
print('resolved:', ' '.join(missing) if missing else '(no new tokens)')
PYEOF

BUDGET=2
# BH-1585: `pool-*-*` is a subset of `*-*`, so every pool record came round TWICE
# and was read twice. Each record is visited once.
declare -A SEEN_REC=()
PR_URL_RE='https://github.com/[^ ]+/pull/[0-9]+'
for D in "$H"/builds/pool-*-*/ "$H"/builds/*-*/; do
  [ "$BUDGET" -gt 0 ] || break
  [ -n "${SEEN_REC[$D]:-}" ] && continue
  SEEN_REC[$D]=1
  [ -f "$D/RESULT" ] || continue
  # No fork per record (BH-6044): this loop visits every project's records, so
  # line 1 is read with `read` and the URL and project tests are bash matches.
  R=""; { IFS= read -r R < "$D/RESULT"; } 2>/dev/null
  case "$R" in "PR_CREATED https://"*) ;; *) continue ;; esac
  PR=""; [[ "$R" =~ $PR_URL_RE ]] && PR="${BASH_REMATCH[0]}"
  [ -n "$PR" ] || continue
  case "$PR" in */"$PROJECT"/*) ;; *) continue ;; esac
  grep -qxF "$PR" "$SKIP" && continue
  verdict_is APPROVE -L "$D/review.md" 2>/dev/null || continue
  # BH-1585: a record whose PR is known merged (or closed, inside the recheck
  # window) costs no call at all; every other one is ONE REST read, and a
  # merged/closed answer is written onto the record so the next run skips it.
  command -v prt_read >/dev/null 2>&1 || continue
  prt_known_terminal "$D" "$PR" && continue
  PRJ=$(mktemp "${TMPDIR:-/tmp}/rebase-train-pr.XXXXXX") || continue
  PRC=0; prt_read "$D" "$PR" "$PRJ" || PRC=$?
  STATE=""; [ "$PRC" = 0 ] && STATE=$(prt_fields "$PRJ")
  rm -f "$PRJ"
  read -r PSTATE PMERGE PAUTHOR BR _ <<<"$STATE"
  [ "${PSTATE:-}" = "OPEN" ] && [ "${PMERGE:-}" = "DIRTY" ] && harness_pr_author_match "${PAUTHOR:-}" || continue

  STRIKES=$(grep -c "STRIKE $PR$" "$LOG" 2>/dev/null); STRIKES=${STRIKES:-0}
  if [ "$STRIKES" -ge 2 ]; then
    echo "$PR" >> "$SKIP"
    HARNESS="$H" "$H/bin/alert-line.sh" "[rebase-train] $PR parked after 2 failed rounds — the merge conductor classifies it conflict-unresolvable and bin/blocked-resolver.sh rebuilds the ticket fresh against current main"
    continue
  fi

  WT="/root/worktrees/train-$PROJECT-$(basename "$PR")"
  echo "$(STAMP) [$PROJECT] $PR rebasing ($BR)" >> "$LOG"
  (
    set -e
    cd "$REPO"
    git fetch origin "$BASE" "$BR" --quiet
    # The head this rebase starts from: the push below leases on it (BH-2504).
    TRAIN_LEASE=$(git rev-parse --verify -q "origin/$BR")
    git worktree remove --force "$WT" 2>/dev/null || true
    git worktree add "$WT" "origin/$BR" --quiet
    cd "$WT"
    git rebase "origin/$BASE" >/dev/null 2>&1 || true
    # Two deterministic conflict classes get auto-resolved, per stopped commit
    # (a multi-commit rebase can stop more than once); anything else strikes.
    # (1) package.json test-script token union. (2) Markdown both-sides-append
    # — CLAUDE.md/build-log/RECENT-CHANGES conflicts where each build appends
    # its own section at the same anchor: keep BOTH blocks, main's first (the
    # by-hand resolution used on project-2 #322, project-3 #215, project-5 #29 — every
    # one was this shape).
    ROUNDS=0
    while [ -d "$(git rev-parse --git-path rebase-merge)" ] || [ -d "$(git rev-parse --git-path rebase-apply)" ]; do
      ROUNDS=$((ROUNDS+1))
      [ "$ROUNDS" -le 6 ] || { git rebase --abort 2>/dev/null || true; echo "$(STAMP) [$PROJECT] STRIKE $PR" >> "$LOG"; echo "$(STAMP) [$PROJECT] $PR rebase stopped >6 times — left for judgment" >> "$LOG"; exit 0; }
      FAIL=0
      for CF in $(git diff --name-only --diff-filter=U); do
        case "$CF" in
          package.json)
            python3 "$RESOLVER" >> "$LOG" 2>&1 || { FAIL=1; break; }
            git add package.json ;;
          vercel.json)
            python3 - <<'VJEOF' || { FAIL=1; break; }
import json, re, sys
# Both-added crons[]-entry conflicts (project-1 #580, 2026-08-19): each side
# added its own {path, schedule} fields inside one object slot. Union = close
# the first object, open the second. Anything that doesn't json-parse after
# the merge, or that DROPS a pre-existing cron path, fails to the strike path.
p = 'vercel.json'
s = open(p).read()
def union(m):
    return m.group(1) + '\n    },\n    {\n' + m.group(2) + '\n'
new, n = re.subn(r'<<<<<<< [^\n]*\n(.*?)\n=======\n(.*?)\n>>>>>>> [^\n]*\n', union, s, flags=re.S)
if n == 0 or '<<<<<<<' in new:
    sys.exit(1)
try:
    d = json.loads(new)
except Exception:
    sys.exit(1)
paths = [c.get('path') for c in d.get('crons', [])]
if len(paths) != len(set(paths)):
    sys.exit(1)   # duplicate cron = the union guessed wrong
open(p, 'w').write(new)
VJEOF
            git add vercel.json ;;
          *.md)
            python3 - "$CF" <<'MDEOF' || { FAIL=1; break; }
import re, sys
p = sys.argv[1]
s = open(p).read()
def union(m):
    return m.group(1) + "\n\n" + m.group(2) + "\n"
new, n = re.subn(r'<<<<<<< [^\n]*\n(.*?)\n=======\n(.*?)\n>>>>>>> [^\n]*\n', union, s, flags=re.S)
if n == 0 or '<<<<<<<' in new:
    sys.exit(1)
open(p, 'w').write(new)
MDEOF
            git add "$CF" ;;
          *) FAIL=1; break ;;
        esac
      done
      if [ "$FAIL" = 1 ]; then
        CONF=$(git diff --name-only --diff-filter=U | tr '\n' ' ')
        git rebase --abort 2>/dev/null || true
        echo "$(STAMP) [$PROJECT] STRIKE $PR" >> "$LOG"
        echo "$(STAMP) [$PROJECT] $PR conflict outside the auto classes (${CONF:-resolver failed}) — left for judgment" >> "$LOG"
        exit 0
      fi
      GIT_EDITOR=true git rebase --continue >/dev/null 2>&1 || true
    done
    [ "$ROUNDS" -gt 0 ] && echo "$(STAMP) [$PROJECT] $PR conflicts auto-unioned across $ROUNDS stop(s)" >> "$LOG"
    cp -al "$REPO/node_modules" node_modules 2>/dev/null || true
    npx prisma generate >/dev/null 2>&1 || true
    # Baseline-aware typecheck: some repos carry known-red baseline errors
    # (project-2: brand.tsx png decl + vendor oauth tests). A rebase is pushable
    # when it introduces NO NEW error lines vs origin/$BASE — computed once
    # per train run per project and cached.
    BASEF="$H/state/tsc-baseline-$PROJECT.txt"
    if [ ! -s "$BASEF" ] || [ "$(find "$BASEF" -mmin -240 2>/dev/null | wc -l)" -eq 0 ]; then
      # Throwaway worktree — NEVER check out $BASE in the shared repo (builds
      # hold worktrees off it; flipping its HEAD mid-build corrupts them).
      BWT="/root/worktrees/train-baseline-$PROJECT"
      ( cd "$REPO" && git worktree remove --force "$BWT" 2>/dev/null; git worktree add "$BWT" "origin/$BASE" --quiet ) 2>/dev/null || : > "$BASEF"
      if [ -d "$BWT" ]; then
        ( cd "$BWT" && cp -al "$REPO/node_modules" node_modules 2>/dev/null; npx prisma generate >/dev/null 2>&1; \
          NODE_OPTIONS=--max-old-space-size=6144 npx tsc --noEmit 2>&1 | grep "error TS" | sort -u > "$BASEF" ) || : > "$BASEF"
        git -C "$REPO" worktree remove --force "$BWT" 2>/dev/null || true
      fi
    fi
    # The generated prisma client matches whatever schema last ran generate —
    # after the baseline worktree pass above, that's the BASE schema. A rebased
    # branch that touches schema.prisma or prisma/schema/ then typechecks and unit-tests against
    # the stale client and strikes falsely (project-3 TK-80/TK-81, 2026-08-23).
    # Regenerate for THIS tree before verifying it.
    # >>> prisma regenerate (BH-1171)
    { [ -f prisma/schema.prisma ] || [ -d prisma/schema ]; } && npx prisma generate >/dev/null 2>&1
    # <<< prisma regenerate
    NODE_OPTIONS=--max-old-space-size=6144 npx tsc --noEmit 2>&1 | grep "error TS" | sort -u > /tmp/train-tsc-$$.txt || true
    NEWERR=$(comm -13 "$BASEF" /tmp/train-tsc-$$.txt | wc -l); rm -f /tmp/train-tsc-$$.txt
    [ "$NEWERR" -eq 0 ] \
      || { echo "$(STAMP) [$PROJECT] STRIKE $PR" >> "$LOG"; echo "$(STAMP) [$PROJECT] $PR typecheck: $NEWERR NEW error(s) vs baseline — not pushed" >> "$LOG"; exit 0; }
    if grep -q '"test:unit"' package.json; then
      npm run test:unit >/dev/null 2>&1 \
        || { echo "$(STAMP) [$PROJECT] STRIKE $PR" >> "$LOG"; echo "$(STAMP) [$PROJECT] $PR unit tests RED post-rebase — not pushed" >> "$LOG"; exit 0; }
    fi
    # >>> caller check (BH-6718)
    # The BH-5791 caller check, on the head this train is about to push. A rebase
    # onto a main that added a caller of an interface this PR changes (the #4332
    # class) passes typecheck in shell, SQL, JSON and untyped JS. So the approval
    # carries over only when the check ran and left no caller gone or unexplained.
    # Anything else still pushes, but the head-bound block below does not rebind,
    # and a found caller asks the lead to review the new head. A check that could
    # not run is not a pass. CALLER_CHECK_MAX_LINES=0 (the BH-5791 off switch)
    # keeps the old rebind.
    TRAIN_REBIND=0; CK_N=0; CK_WHY=""; CK_IFS=""
    # shellcheck source=bin/lib/caller-check.sh
    command -v cc_conf >/dev/null 2>&1 || . "$H/bin/lib/caller-check.sh" 2>/dev/null || true
    if ! command -v cc_conf >/dev/null 2>&1 || [ ! -x "$H/bin/caller-check.sh" ]; then
      CK_WHY="could-not-run (the caller-check lib or CLI is missing on $(hostname))"
    else
      cc_conf "$PROJECT"
      if [ "$CK_MAX_LINES" = 0 ]; then
        TRAIN_REBIND=1
        echo "$(STAMP) [$PROJECT] $PR caller check: off (CALLER_CHECK_MAX_LINES=0) — the approval is rebound as before" >> "$LOG"
      else
        CK_BASE=$(git merge-base "origin/$BASE" HEAD 2>/dev/null) || CK_BASE=unresolved
        CK_PLAN=/dev/null; [ -s "$D/plan.md" ] && CK_PLAN="$D/plan.md"
        CK_OUT="$D/callers-rebase-train.txt"; CK_RC=0; CK_SUM=""
        "$H/bin/caller-check.sh" --repo . --base "$CK_BASE" --head HEAD --plan "$CK_PLAN" \
          --out "$CK_OUT" >/dev/null 2>>"$LOG" || CK_RC=$?
        { IFS= read -r CK_SUM < "$CK_OUT"; } 2>/dev/null || true
        CK_SUM=${CK_SUM#CALLERS: }
        if [ "$CK_RC" = 0 ] && [[ "$CK_SUM" =~ noreason=([0-9]+)\ gone=([0-9]+) ]]; then
          CK_N=$(( BASH_REMATCH[1] + BASH_REMATCH[2] ))
          if [ "$CK_N" = 0 ]; then
            TRAIN_REBIND=1
            echo "$(STAMP) [$PROJECT] $PR caller check: $CK_SUM — the approval carries over" >> "$LOG"
          else
            CK_IFS=$(awk -F'\t' '$1 == "CALLER" && $4 == "left alone" && ($5 == "no reason in the plan" || $5 ~ /^definition gone/) && !s[$2]++ { o = o (n++ ? "," : "") $2 } END { print o }' "$CK_OUT" 2>/dev/null) || CK_IFS=""
            CK_WHY="$CK_SUM on ${CK_IFS:-an unnamed interface}"
          fi
        else
          CK_WHY="could-not-run (rc=$CK_RC${CK_SUM:+: $CK_SUM})"
        fi
      fi
    fi
    [ -z "$CK_WHY" ] || echo "$(STAMP) [$PROJECT] $PR caller check: $CK_WHY — the approval will NOT be rebound" >> "$LOG"
    # <<< caller check (BH-6718)
    # The ticket's hold is re-read at the push, and the lease is the head this
    # rebase began from (BH-2504) — never a bare --force-with-lease, whose
    # expected value is whatever the last fetch happened to see.
    # shellcheck source=bin/lib/hold-push.sh
    . "$(dirname "${BASH_SOURCE[0]}")/lib/hold-push.sh" 2>/dev/null || . "$H/bin/lib/hold-push.sh"
    HOLD_PUSH_LOG="$LOG" hold_push "$PROJECT" - "$WT" origin HEAD "$BR" "$TRAIN_LEASE" 2>/dev/null \
      || { echo "$(STAMP) [$PROJECT] $PR rebased + verified but NOT pushed (a HOLD on the ticket, an unreadable hold, or the branch moved) — left as it was" >> "$LOG"; exit 0; }
    # >>> head-bound approval
    # SDLC item 1: the sweep is head-bound now, so a train that pushes a NEW
    # head without moving the approval onto it would hand the sweep a mismatch
    # on every PR it touches — a park and a hand merge each time, which is
    # exactly the starvation class this train was built to kill. This rebase is
    # mechanical work on the tree a reviewer already read: union-resolved to two
    # deterministic conflict classes only, typechecked against main's own
    # baseline, unit-tested. So it rebinds, the same way bin/run-build.sh
    # carries its own pre-PR rebase forward and bin/merge-queue.sh its own.
    #
    # REBINDS, NEVER CLAIMS: both writes only move a sha that already exists.
    # A record or a ledger row that made no head-bound claim keeps making none
    # (job_verdict_rebind returns 2 and writes nothing), so a train run cannot
    # turn a pre-item-1 build into a gated one.
    NEWSHA=$(git rev-parse HEAD)
    if [ "${TRAIN_REBIND:-1}" = 1 ]; then
      if [ -s "$D/reviewed-sha" ]; then echo "$NEWSHA" > "$D/reviewed-sha"; fi
      if type job_verdict_rebind >/dev/null 2>&1; then
        if job_verdict_rebind "$PR" "$NEWSHA" >/dev/null 2>&1; then
          echo "$(STAMP) [$PROJECT] $PR approval rebound to the rebased head $NEWSHA" >> "$LOG"
        fi
      fi
    else
      # BH-6718: the caller check above did not pass. Neither write runs: the
      # sweep sees a head nobody reviewed and holds it. A found caller asks the
      # lead for a review of THIS head (pushed above, so the lead can read it).
      echo "$(STAMP) [$PROJECT] $PR approval NOT rebound to $NEWSHA (caller check)" >> "$LOG"
      if [ "${CK_N:-0}" -gt 0 ]; then
        CK_SLUG=${PR#https://github.com/}; CK_SLUG=${CK_SLUG%/pull/*}; LV_RC=0
        "$H/bin/lead-verdict.sh" request "$CK_SLUG" "${PR##*/}" "$NEWSHA" \
          --notes "rebase-train: caller check found $CK_N callers (${CK_IFS:-unnamed})" >/dev/null 2>>"$LOG" || LV_RC=$?
        if [ "$LV_RC" = 0 ]; then
          echo "$(STAMP) [$PROJECT] $PR lead review requested on ${NEWSHA:0:12}" >> "$LOG"
        else
          echo "$(STAMP) [$PROJECT] $PR lead review request failed (rc=$LV_RC) — the sweep holds the PR until a review binds ${NEWSHA:0:12}" >> "$LOG"
        fi
      fi
    fi
    # <<< head-bound approval
    # >>> train final line (BH-6718)
    if [ "${TRAIN_REBIND:-1}" = 1 ]; then
      echo "$(STAMP) [$PROJECT] $PR rebased + verified + pushed — sweep takes it next tick" >> "$LOG"
    else
      echo "$(STAMP) [$PROJECT] $PR rebased + verified + pushed — NOT rebound, the sweep waits for a review of the new head" >> "$LOG"
    fi
    # <<< train final line
  )
  git -C "$REPO" worktree remove --force "$WT" 2>/dev/null || true
  BUDGET=$((BUDGET-1))
done
exit 0
