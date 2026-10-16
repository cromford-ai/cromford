#!/bin/bash
# Deterministic triage gate (cost lever 1, 2026-07-24): decide WITHOUT an LLM
# whether this cron tick needs a triage session at all. Most ticks conclude
# "board unchanged, no queue, no results to sweep" — that used to cost a full
# Opus session per tick per project.
#
# usage: triage-gate.sh <project>          -> prints "RUN <reason>" or "SKIP <reason>"
#        triage-gate.sh <project> --seed   -> fetch + store fingerprint, mark full run now
#        triage-gate.sh <project> --signal <tid> -> one ticket's signal digest (BH-2542), rc 1 = none
#        triage-gate.sh <project> --thread <tid> -> one ticket's thread as JSON (TRIAGE-STATE), rc 1 = none
#        triage-gate.sh <project> --buildable-strict <tid> -> --buildable, but a read that fails is
#                                  BLOCKED unreadable (TRIAGE-STATE launches fail closed)
# Always exits 0. FAIL-OPEN: any fetch/parse problem prints RUN — a broken gate
# spends money, never misses a ticket. ONE fail-CLOSED exception (BH-1955): on
# the generic in-app arm, an env file whose token/base cannot be resolved to
# exactly one variable (none, two, empty value) prints SKIP token-unresolved
# (BLOCKED token-unresolved under --buildable) after one ALERTS line, and
# fetches nothing. That is a credential bug, not API weather. --pending is NOT
# closed by itself: it exits 1, which bin/lib/rt/scope.sh reads as "board state
# unknown, run with full context". It is only asked on a tick the plain gate
# already answered RUN, and the plain gate answers SKIP for this same env file,
# so it is reached only if the env file changed between the two calls.
#
# Fingerprint = per ticket (id,status,waitingOn,triageVerdict,commentCount,
# lastActivityAt,title) across ALL boards — the same DIFF KEYS the triage
# prompts use. Comment-only updates bump commentCount/lastActivityAt.
# A board that serves the DEPENDENCY primitive (docs/BOARD-API-CONTRACT.md,
# "Dependencies") adds four more per ticket: key, blocked, parentId and the ids
# in dependsOn — so a blocker landing flips `blocked` and the fingerprint diff
# wakes a scoped tick for the child it released (BH-815). DETECTED PER TICKET ON
# THE TYPE OF `blocked`: only a JSON boolean counts, so an absent or null field
# leaves that ticket's fingerprint byte-identical to what it was before this
# existed. That matters because every in-app board on the fleet is that board
# until it deploys the contract, and re-fingerprinting all of them would buy one
# full session per project for nothing.
# Un-adopted rows OMIT the four keys rather than projecting them to null:
# byte-identical wins, because a null key would re-fingerprint six boards and
# buy six paid sessions for nothing. Do not "fix" this.
# GitHub-Issues boards additionally carry the OPEN harness PRs (number, head
# sha, state) so a merge, close or rebase wakes the tick.
# Safety net: one forced full run per FULL_SWEEP_SECS (default 24h).
#
# THE GITHUB READS ARE REST (BH-782). Both of them go through
# bin/lib/gh-rest.sh, so an answer we could not read arrives as an HTTP status
# and takes this file's documented fail-OPEN arm (RUN) rather than being read as
# a board with nothing on it. `mergeStateStatus` LEFT the PR fingerprint with
# that move: REST list responses do not carry it, buying it back would cost one
# GET /pulls/{n} per open PR per tick, and the queue gate below already argues
# that the field "churns (BEHIND/UNKNOWN/CLEAN) without changing what the
# session would do". A merge, a close, a rebase, a new comment or a state change
# all still wake the tick; a bare check flip no longer does.
#
# gh-rest: no-graphql
set -uo pipefail
# BH-1138: no __pycache__ next to bin/*.py. The interpreter writes bytecode
# beside any module it IMPORTS; gitignore has no say over a path that is
# already tracked, and a whole-tree `git add -A` then re-commits it — which
# is how bin/__pycache__/gate-selfwrite.cpython-312.pyc reached main twice.
# The staging exclusions in bin/lane-checkpoint.sh and bin/lander.sh are the
# belt; this is the brace, and the only half that means the file never exists.
export PYTHONDONTWRITEBYTECODE=1
PROJECT="${1:?project}"
MODE="${2:-}"
HARNESS="${HARNESS:-/root/harness}"
. "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$HARNESS")
GATE="$HARNESS/state/$PROJECT.gate.json"

# Builder results waiting is ALWAYS a run reason (2026-08-02: three Fly results
# sat unswept 7h — close-outs and child launches starved behind a "no-change" board).
# (--signal is a per-ticket read and never answers RUN/SKIP, BH-2542.)
if [ "$MODE" != "--signal" ] && [ "$MODE" != "--thread" ] && [ "$MODE" != "--buildable-strict" ] && ls "$HARNESS/state/remote-results/$PROJECT/"*.json >/dev/null 2>&1; then
  echo "RUN remote-results-pending"; exit 0
fi
PENDING="$HARNESS/state/$PROJECT.gate.pending"
META="$HARNESS/state/$PROJECT.gate-meta"
FULL_SWEEP_SECS="${FULL_SWEEP_SECS:-86400}"

set -a
[ -f "$HENV/global.env" ] && . "$HENV/global.env"
[ -f "$HENV/$PROJECT.env" ] && . "$HENV/$PROJECT.env"
set +a
# BH-4080: HARNESS_OPERATOR_LOGIN, the self actor when the author set is empty.
# shellcheck source=bin/lib/deployment.sh
. "${HARNESS_DEPLOYMENT_FILE-$(dirname "${BASH_SOURCE[0]}")/lib/deployment.sh}" || exit 1

# WHOSE the harness's own writes are. The author SET (bin/lib/gh-pr-list.sh,
# HARNESS_PR_AUTHORS): on an issue board our own comments come from the PAT
# login OR from the GitHub App (`cromford[bot]`) since bin/gh-token.sh went
# live, and a self-write the gate does not recognise reads as client activity
# and pays for a tick (2026-09-14, the PR-author incident's board-side twin).
# A tree without the lib keeps the PAT login it has always used.
# shellcheck source=bin/lib/gh-pr-list.sh
for _P in "$(dirname "$0")/lib/gh-pr-list.sh" "$HARNESS/bin/lib/gh-pr-list.sh"; do
  # shellcheck source=/dev/null
  [ -r "$_P" ] && { . "$_P"; break; }
done
# The REST contract (#780), same two-rung source. An absent lib leaves gh_rest
# undefined and fetch_fingerprint returns 1 — which is this file's fail-OPEN.
for _P in "$(dirname "$0")/lib/gh-rest.sh" "$HARNESS/bin/lib/gh-rest.sh"; do
  # shellcheck source=/dev/null
  [ -r "$_P" ] && { . "$_P"; break; }
done
# BH-2133: bot-only comment bumps on a GitHub-Issues board are absorbed. No lib
# = today's behaviour (every bump wakes the tick).
for _P in "$(dirname "$0")/lib/gate-self-comments.sh" "$HARNESS/bin/lib/gate-self-comments.sh"; do
  # shellcheck source=/dev/null
  [ -r "$_P" ] && { . "$_P"; break; }
done
# THE READY SET (BH-1033). "What is ready to build" is the READY-QUEUE.log
# lines UNION the `ready` build_queue rows, and it has exactly one definition —
# this lib. With the flag off, or the lib absent, every read below is the grep
# it always was.
# shellcheck source=bin/lib/ready-queue.sh
for _P in "$(dirname "$0")/lib/ready-queue.sh" "$HARNESS/bin/lib/ready-queue.sh"; do
  # shellcheck source=/dev/null
  [ -r "$_P" ] && { . "$_P"; break; }
done
# BH-2318: the gate's state has a ledgers(kind=triage_gate) twin keyed by
# project, so a moved or rebuilt box restores it instead of re-buying a full
# triage. Dark behind the no-twin-ledgers flag; no lib, or no client, is today.
# shellcheck source=/dev/null
declare -F job_ledger_get >/dev/null 2>&1 || { [ -r "$HARNESS/bin/jobs-client.sh" ] && . "$HARNESS/bin/jobs-client.sh"; }
for _P in "$(dirname "$0")/lib/triage-gate-ledger.sh" "$HARNESS/bin/lib/triage-gate-ledger.sh"; do
  # shellcheck source=/dev/null
  [ -r "$_P" ] && { . "$_P"; break; }
done
# BH-2350: the builds-of-record reader, for section 3b. No lib, no 3b.
for _P in "$(dirname "$0")/lib/builds-of-record.sh" "$HARNESS/bin/lib/builds-of-record.sh"; do
  # shellcheck source=/dev/null
  [ -r "$_P" ] && { . "$_P"; break; }
done
command -v tgl_put_gate >/dev/null 2>&1 || { tgl_put_gate() { :; }; tgl_hydrate_meta() { return 1; }; tgl_read_gate() { return 1; }; tgl_hydrate_gate() { return 1; }; }
command -v rq_any   >/dev/null 2>&1 || rq_any()   { grep -qE '^[A-Z]+-[0-9]' "${1:-$HARNESS}/logs/READY-QUEUE.log" 2>/dev/null; }
command -v rq_lines >/dev/null 2>&1 || rq_lines() { grep -E  '^[A-Z]+-[0-9]' "${1:-$HARNESS}/logs/READY-QUEUE.log" 2>/dev/null; }
command -v rq_fp    >/dev/null 2>&1 || rq_fp()    { :; }
command -v rq_fp_file >/dev/null 2>&1 || rq_fp_file() { cat "${1:-$HARNESS}/logs/READY-QUEUE.log" 2>/dev/null; }

HARNESS_SELF_ACTORS=$(command -v harness_pr_authors_csv >/dev/null 2>&1 && harness_pr_authors_csv)
[ -n "$HARNESS_SELF_ACTORS" ] || HARNESS_SELF_ACTORS="$HARNESS_OPERATOR_LOGIN"

case "$PROJECT" in
  project-1)   BASE="${PROJECT_1_API_BASE:-}"; TOKEN="${PROJECT_1_INTERNAL_API_TOKEN:-}"; BP="/api/board"; SELF_ACTORS="project-1 Team Harness" ;;
  project-2) BASE="${PROJECT_2_APP_BASE:-}";       TOKEN="${PROJECT_2_INTERNAL_API_TOKEN:-}";       BP="/api/board"; SELF_ACTORS="project-2 Harness" ;;
  project-3)       BASE="${PROJECT_3_APP_BASE:-}";     TOKEN="${PROJECT_3_INTERNAL_API_TOKEN:-}";     BP="/api/feature-board"; SELF_ACTORS="project-3 AI Harness" ;;
  project-4)       BASE="${PROJECT_4_API_BASE:-}";     TOKEN="${PROJECT_4_INTERNAL_API_TOKEN:-}";     BP="/api/accounting/requests-board"; SELF_ACTORS="system-board Harness" ;;
  *)
    # Generic arm (2026-08-18): any fleet.conf project whose board-prefix is
    # "-" is a GitHub-Issues board (project-5 and project-6 included: their
    # literal slugs went in BH-4080) — fingerprint it via gh exactly like
    # project-5 (load-project.sh onboards small projects this way). Everything
    # else stays fail-open RUN.
    # JIRA (BH-4076), --buildable[-strict] only: a project whose env file sets
    # JIRA_BASE AND whose tracker_adapter.<project> row is `jira` reads the
    # ticket through bin/lib/tracker/jira.sh, and buildable_gate runs its usual
    # checks on that read. A context that does not load (credentials, a
    # malformed allowlist row, the settings worker down) is the token-unresolved
    # block the board arm gives. Every other project, and every other mode,
    # never gets here and pays no settings call.
    JIRA_GATE=""
    if { [ "$MODE" = "--buildable" ] || [ "$MODE" = "--buildable-strict" ]; } && [ -n "${JIRA_BASE:-}" ]; then
      for _P in "$(dirname "$0")/lib/tracker.sh" "$HARNESS/bin/lib/tracker.sh"; do
        # shellcheck source=/dev/null
        [ -r "$_P" ] && { . "$_P"; break; }
      done
      if declare -F tracker_adapter >/dev/null 2>&1 && [ "$(tracker_adapter "$PROJECT" 2>/dev/null)" = jira ]; then
        if tracker_load jira && trk_jira_context "$PROJECT" 2>/dev/null; then
          JIRA_GATE=1; SELF_ACTORS=""
        else
          echo "BLOCKED token-unresolved"; exit 0
        fi
      fi
    fi
    BP_CONF=$("$HARNESS/bin/fleet-conf.sh" "$PROJECT" board_prefix 2>/dev/null || true)
    REPO_CONF=$("$HARNESS/bin/fleet-conf.sh" "$PROJECT" repo 2>/dev/null || true)
    if [ -n "$JIRA_GATE" ]; then
      :
    elif [ "$BP_CONF" = "-" ] && [ -n "$REPO_CONF" ]; then
      GH_ISSUES_REPO="$REPO_CONF"; SELF_ACTORS="$HARNESS_SELF_ACTORS"
    elif [ -n "$BP_CONF" ]; then
      # In-app product board, generically: env vars are discovered by suffix
      # (the env-templates contract) — <PREFIX>_API_BASE / <PREFIX>_APP_BASE +
      # <PREFIX>_INTERNAL_API_TOKEN, board prefix from fleet.conf.
      # WHICH variable is which comes from bin/lib/internal-token.sh through
      # bin/lib/board-creds.sh (BH-1955), never `grep | head -1`: that took no
      # digit prefix (project-32_) and silently used the first of two tokens. No
      # match, a duplicate, an empty value or no lib is a TOKEN problem, and
      # this is the one fail-CLOSED exit in this file: one ALERTS line (the lib
      # dedups per project per day), no fetch, and SKIP/BLOCKED rather than a
      # paid RUN against a board we would call with a guessed credential.
      BASE_VAR=""; TOKEN_VAR=""; BASE=""; TOKEN=""
      for _P in "$(dirname "$0")/lib/board-creds.sh" "$HARNESS/bin/lib/board-creds.sh"; do
        # shellcheck source=/dev/null
        [ -r "$_P" ] && { . "$_P"; break; }
      done
      if command -v board_token_var >/dev/null 2>&1 \
        && TOKEN_VAR=$(board_token_var "$PROJECT" "$HENV/$PROJECT.env" triage-gate) \
        && BASE_VAR=$(board_base_var "$PROJECT" "$HENV/$PROJECT.env" triage-gate); then
        BASE="${!BASE_VAR:-}"; TOKEN="${!TOKEN_VAR:-}"
      fi
      BP="$BP_CONF"; SELF_ACTORS="${BOARD_SELF_ACTORS:-System} Harness"
      if [ -z "$BASE" ] || [ -z "$TOKEN" ]; then
        # Both names resolved, so the lib said nothing: the value is what is
        # empty (BH-2106). Same line, same per-project per-day flag.
        if [ -n "$TOKEN_VAR" ] && [ -n "$BASE_VAR" ] && command -v _bc_alert >/dev/null 2>&1; then
          if [ -z "$TOKEN" ]; then _EMPTY_VAR="$TOKEN_VAR"; else _EMPTY_VAR="$BASE_VAR"; fi
          _bc_alert "$PROJECT" "$HENV/$PROJECT.env sets $_EMPTY_VAR to an empty value" triage-gate
        fi
        case "$MODE" in
          --buildable|--buildable-strict) echo "BLOCKED token-unresolved" ;;
          --pending)   exit 1 ;;
          --signal|--thread) exit 1 ;;
          *)           echo "SKIP token-unresolved" ;;
        esac
        exit 0
      fi
    else
      case "$MODE" in --signal|--thread) exit 1 ;; esac
      echo "RUN unknown-project"; exit 0
    fi ;;
esac

# Fingerprint is ONE JSON object {boardId: [ticket,...]} so the self-write
# classifier can diff it. Old "bid:[...]" text fingerprints fail to parse there
# and fail-open to RUN, which then absorbs the new format — self-migrating.
fetch_fingerprint() { # -> fingerprint on stdout, rc!=0 on any failure
  command -v jq >/dev/null || return 1
  # GitHub-Issues boards (project-5): the fingerprint is the ai-build issue
  # list — number, state, title, comment count, updatedAt. Unchanged list =
  # nothing a fresh session could conclude differently ($148/day of paid
  # unknown-project fail-open ticks before this branch existed, 2026-08-17).
  if [ -n "${GH_ISSUES_REPO:-}" ]; then
    local iss prs gf meta rc=0
    command -v gh_rest >/dev/null 2>&1 || return 1
    # The raw GET below builds its own API path, so the slug does not get the
    # shape check the gh_rest_* helpers run. $GH_ISSUES_REPO is operator-set;
    # this guards the sink, it does not defend against a live attacker.
    if command -v _gh_rest_args_ok >/dev/null 2>&1; then
      _gh_rest_args_ok "$GH_ISSUES_REPO" || return 1
    fi
    gf=$(mktemp) || return 1
    # `> file`, never `$( )`: the status has to survive into this shell.
    gh_rest GET "repos/$GH_ISSUES_REPO/issues" -f labels=ai-build -f state=all -F per_page=100 \
      > "$gf" || rc=$?
    [ "$rc" = 0 ] || { rm -f "$gf"; return 1; }
    # REST /issues returns PULL REQUESTS too; they are filtered out so the
    # fingerprint stays a fingerprint of the issue threads.
    #
    # `comments` IS A COUNT HERE, AND THE GraphQL FIELD WAS A LIST — declared,
    # not glossed (BH-782 review r2). What it buys: a new comment moves the
    # count, so the wake signal this tick exists for is unchanged, at no extra
    # call. What it costs, exactly: a comment DELETED and another ADDED between
    # two ticks leaves the count equal, so that pair alone no longer wakes the
    # tick on its own. `updated_at` moves on both, and it is in this same
    # fingerprint, so the pair still wakes it through that field — the count is
    # the cheap signal, not the only one. The first tick after this ships sees
    # every board's fingerprint change shape once and wakes; that is a single
    # extra session per board, not a loop.
    iss=$(jq -c '[.[] | select(.pull_request == null)
                  | {number, state: (.state|ascii_upcase), title, comments, updatedAt: .updated_at}]' "$gf" 2>/dev/null) \
      || { rm -f "$gf"; return 1; }
    [ -n "$iss" ] || { rm -f "$gf"; return 1; }
    # THE CONTENT A HUMAN EDITS WITHOUT COMMENTING (BH-2133 review, B1): per
    # issue, the sha256 of its body, sorted label names, sorted assignees and
    # milestone, as a top-level `meta` map {number: hash}. Kept OUT of the issue
    # rows, so bin/gate-diff.sh and the shard fingerprint read exactly what they
    # read before, and step 6 below compares with `meta` left out (it only moves
    # when updatedAt does). Its one job: gate_self_absorb absorbs a bot note
    # only when this hash is identical to the consumed one, so an edit made
    # while a session was in flight is never folded into our own note.
    # Unreadable = `{}`, which absorbs nothing.
    meta=$(python3 - "$gf" 2>/dev/null <<'PYEOF'
import hashlib, json, sys
out = {}
for i in json.load(open(sys.argv[1])):
    if not isinstance(i, dict) or i.get("pull_request") is not None:
        continue
    m = i.get("milestone") or {}
    t = json.dumps([i.get("body") or "",
                    sorted(str((l or {}).get("name", "")) for l in (i.get("labels") or []) if isinstance(l, dict)),
                    sorted(str((a or {}).get("login", "")) for a in (i.get("assignees") or []) if isinstance(a, dict)),
                    [m.get("number"), m.get("title")] if isinstance(m, dict) else None],
                   sort_keys=True, separators=(",", ":"))
    out[str(i.get("number"))] = hashlib.sha256(t.encode()).hexdigest()[:16]
print(json.dumps(out, sort_keys=True, separators=(",", ":")))
PYEOF
) || meta='{}'
    [ -n "$meta" ] || meta='{}'
    # OUR OWN COMMENTS ARE NOT THE BOARD MOVING (BH-2133). A row whose only
    # movement since the consumed fingerprint is comments written by one of the
    # harness's own Apps keeps the consumed count/updatedAt, so the gate, the
    # event-wake diff and the shard fingerprint all read it unchanged.
    # bin/lib/gate-self-comments.sh has the rule and every case that still
    # wakes; it prints $iss unchanged on any doubt. Not on --seed: a seed takes
    # the board exactly as it is.
    if [ "$MODE" != "--seed" ] && command -v gate_self_absorb >/dev/null 2>&1; then
      iss=$(gate_self_absorb "$HARNESS" "$PROJECT" "$GH_ISSUES_REPO" "$iss" "$GATE" "$meta") || { rm -f "$gf"; return 1; }
      [ -n "$iss" ] || { rm -f "$gf"; return 1; }
    fi
    # The OPEN harness PRs ride along (2026-09-12): number, head sha, state. A
    # fingerprint of the issue threads alone is blind to a PR merging, closing
    # or being rebased — and hand-merged project-5 PRs that closed no issue left
    # the tick answering "gate no-change (63 tickets)" from 06:21Z to 14:49Z
    # while their Blocked-by children waited. One extra REST list per tick; a
    # merged PR leaves the open list, which is the change that wakes the tick.
    #
    # A LIST WE COULD NOT READ FAILS THE WHOLE FETCH (BH-782 review r2), the
    # same as the issue list above it. Writing prs='[]' instead was the obvious
    # move and it is wrong in the one case that matters: on a board that
    # genuinely has no open PRs the substitute fingerprint is byte-identical to
    # the stored one, and the tick answers `SKIP no-change` off a read it never
    # made. It is worse on the second tick of an outage on ANY board, because
    # bin/lib/rt/gate.sh promotes state/<p>.gate.pending into the stored
    # fingerprint once a session has run — so tick 1 stamps prs:[] and tick 2
    # matches it and SKIPs. rc!=0 here is the documented fail-OPEN: the caller
    # prints `RUN gate-fetch-failed`, --pending exits 1 ("run with full
    # context"), --seed prints SEED-FAILED. We never SKIP off a fingerprint we
    # could not compute.
    rc=0
    gh_rest_pr_list "$GH_ISSUES_REPO" open "" 100 > "$gf" || rc=$?
    [ "$rc" = 0 ] || { rm -f "$gf"; return 1; }
    prs=$(jq -c '[.[] | {number, headRefOid: .head.sha, state: (.state|ascii_upcase)}]' "$gf" 2>/dev/null) \
      || { rm -f "$gf"; return 1; }
    rm -f "$gf"
    [ -n "$prs" ] || return 1
    jq -cS -n '{issues: input, prs: input, meta: input}' <<<"$iss"$'\n'"$prs"$'\n'"$meta" || return 1
    return 0
  fi
  [ -n "$BASE" ] && [ -n "$TOKEN" ] || return 1
  local boards ids fp all='{}' rawf capped derived='[]' pfx dk
  boards=$(curl -sf -m 20 -H "Authorization: Bearer $TOKEN" -H "User-Agent: curl/8" "$BASE$BP/boards") || return 1
  ids=$(jq -r '(.boards? // .) | .[]?.id' <<<"$boards" 2>/dev/null) || return 1
  [ -n "$ids" ] || return 1
  while IFS= read -r bid; do
    # Write the listing to a file so a 500-row body never lands on jq argv
    # (same MAX_ARG_STRLEN cliff as the merge below).
    rawf=$(mktemp) || return 1
    curl -sf -m 20 -H "Authorization: Bearer $TOKEN" -H "User-Agent: curl/8" \
      "$BASE$BP/boards/$bid/tickets" -o "$rawf" || { rm -f "$rawf"; return 1; }
    # `(.blocked | type) == "boolean"` and NOT jq's `//`: `false // x` falls
    # through to x, so the alternative operator would read an UNBLOCKED ticket
    # on an adopted board as an un-adopted one. `key` rides inside the same
    # block because the release line in bin/run-triage.sh resolves a dependency
    # id to a key out of this file, and adding it unconditionally would change
    # every existing fingerprint.
    fp=$(jq -S '[(.tickets? // .) | .[]? | {id,status,waitingOn,triageVerdict,commentCount,lastActivityAt,title}
                 + (if ((.blocked | type) == "boolean")
                    then {key, blocked, parentId, dependsOn: [.dependsOn[]? | .id]}
                    else {} end)] | sort_by(.id)' "$rawf") || { rm -f "$rawf"; return 1; }
    # .capped? so a raw ticket array (project-3 feature-board) does not stderr
    # "Cannot index array with string \"capped\"" into ALERTS.log every tick.
    # Fingerprint already tolerates arrays via (.tickets? // .); this must too.
    capped=$(jq -r '.capped? // false' "$rawf")
    # >>> derived keymap rows (BH-1169)
    # A board whose list omits `key` (project-4: CARD_SELECT returns `number`) still
    # names its tickets: the board's keyPrefix plus the number is exactly what
    # formatTicketKey builds on that board, and the parent-key prefix that
    # `# >>> board child keys` in bin/run-decompose.sh derives from was itself
    # formatted from it. Read here, NOT in the fingerprint: `number` in fp would
    # re-fingerprint every board and buy a paid session per project (:24-27).
    # No keyPrefix on the board = nothing derived: a keymap entry may only ever
    # name the BOARD's key for an id, never a guess.
    pfx=$(jq -r --arg bid "$bid" '(.boards? // .) | map(select((.id|tostring) == $bid)) | .[0].keyPrefix // ""' <<<"$boards" 2>/dev/null) || pfx=""
    if [ -n "$pfx" ]; then
      # `(.key // "") == ""` and NOT `== null`: jq reads "" as TRUE, so a board
      # sending an empty-string key would otherwise read as key-bearing and
      # derive nothing. Absent, null and "" all mean this row has no key.
      dk=$(jq -c --arg pfx "$pfx" '[ (.tickets? // .) | .[]?
             | select((.key // "") == "") | select((.number // null) != null)
             | {id, status, key: ($pfx + "-" + (.number|tostring))} ]' "$rawf" 2>/dev/null) || dk='[]'
      derived=$(jq -c '. + input' <<<"$derived"$'\n'"$dk" 2>/dev/null) || derived='[]'
    fi
    # <<< derived keymap rows
    rm -f "$rawf"
    # TK-314: listings past LIST_FETCH_CAP set capped=true and drop the oldest-
    # activity cards. Those are still on the board (GET /tickets/{id} = 200).
    # Union them back from the previous fingerprint so gate-diff does not
    # report phantom REMOVED. Real deletions still surface when capped=false.
    # --slurpfile keeps the prior fingerprint off jq argv (same ARG_MAX cliff).
    if [ "$capped" = "true" ] && [ -s "$GATE" ]; then
      fp=$(jq -cS --arg bid "$bid" --slurpfile prev "$GATE" '
        . as $page
        | ($prev[0][$bid] // []) as $old
        | ($page | map({key:.id, value:true}) | from_entries) as $have
        | $page + [$old[] | select($have[.id] | not)]
        | sort_by(.id)
      ' <<<"$fp") || return 1
    fi
    # --argjson puts $fp on argv. Linux MAX_ARG_STRLEN (~128KiB, distinct from
    # ARG_MAX) is smaller than a real board fingerprint: project-9 434 tickets
    # = 135KB on 2026-08-31, so jq died "Argument list too long", the gate
    # fail-opened RUN gate-fetch-failed, and every 10-min tick bought a full
    # session. Stream both JSON values on stdin instead (`.` = $all, `input` = $fp).
    all=$(jq -cS --arg bid "$bid" '. + {($bid): input}' <<<"$all"$'\n'"$fp") || return 1
  done <<<"$ids"
  # Persist id<->key mapping so queue/result scope lines (which carry the board
  # key, e.g. TK-216) can be resolved back to a ticket id for the buildability
  # gate. Rebuilt every consumed tick; a missing/stale key simply fail-opens.
  # jq 1.7 removed the argfile flag (BH-411 used it). Process-substitution
  # printf then SIGPIPEs, and run-triage.sh 2>> ALERTS.log turns that into a
  # fleet alert every tick (project-9 2026-09-16, 500-ticket fingerprint).
  # Same stdin pattern as the ARG_MAX fix above: here-string, not argv.
  #
  # CLOSED TICKETS ARE LEFT OUT (BH-1042, audit fact #33). The only reader is
  # the client-court guard in bin/lib/rt/shards.sh, which resolves a build key
  # to a ticket id and then asks whether that ticket is buildable. A key that
  # has since been reused, or a map entry left over from a shipped ticket, sent
  # the guard to a DONE ticket and dropped live work. The match is on the
  # status vocabulary this harness and these boards actually write, lower-cased,
  # and it FAILS OPEN: a status nobody here has seen counts as open, because
  # dropping a live key costs a build and keeping a dead one costs one gate call.
  KEYMAP_CLOSED='["done","closed","cancelled","canceled","archived"]'
  jq -S --argjson closed "$KEYMAP_CLOSED" '
     def open: select((((.status // "") | ascii_downcase) as $s | ($closed | index($s))) == null);
     def pair: {(.id | tostring): .key, (.key): (.id | tostring)};
     ([ input | .[] | open | pair ] | add // {})
     + ([ .[] | .[] | select(.key) | open | pair ] | add // {})
  ' <<<"$all"$'\n'"$derived" > "$KEYMAP_FILE" 2>/dev/null || true
  printf '%s' "$all"
}
KEYMAP_FILE="$HARNESS/state/$PROJECT.keymap.json"

# >>> contested-hold gate (BH-590)
# A CONTESTED HOLD (bin/lib/merge-conductor-lib.sh, BH-579) records who won a
# path two tickets both wanted to edit. A ticket whose PRE-PLAN files hit a live
# hold it does not own is not launched this tick — it is re-offered next tick,
# like every other BLOCKED answer here. Nothing waits on anything; this is a
# defer, not a queue.
#
# FAIL-OPEN, like the rest of this gate: no lib, no hold, no key, no pre-plan
# list, a hold that will not parse — every one of them answers OK. The cases
# where a live hold existed and we could NOT decide write one line to
# logs/contested.log, so an unenforced hold is never silent. An empty store logs
# nothing: that is the everyday path.
cg_log() {
  mkdir -p "$HARNESS/logs" 2>/dev/null
  printf '%s %s %s\n' "$(mc_stamp)" "$PROJECT" "$*" >> "$HARNESS/logs/contested.log" 2>/dev/null || true
  return 0
}
contested_gate() { # <ticket-id or KEY> -> OK | BLOCKED contested=<path> winner=<KEY>
  local tid="${1:-}" lib="" p b holds keys="" key plans="" f hp w pkey pf want
  for p in "$(dirname "$0")/lib/merge-conductor-lib.sh" "$HARNESS/bin/lib/merge-conductor-lib.sh"; do
    [ -r "$p" ] && { lib="$p"; break; }
  done
  [ -n "$lib" ] || { echo "OK"; return 0; }
  # shellcheck source=bin/lib/merge-conductor-lib.sh
  command -v mc_contested_list >/dev/null 2>&1 || . "$lib"
  if ! command -v mc_contested_list >/dev/null 2>&1 \
     || ! command -v mc_contested_live >/dev/null 2>&1 \
     || ! command -v mc_contested_wins >/dev/null 2>&1; then
    echo "OK"; return 0   # a tree whose lib predates the contract
  fi
  holds=$(mc_contested_list "$PROJECT" 2>/dev/null) || holds=""
  [ -n "$holds" ] || { echo "OK"; return 0; }

  # The KEY(s) this ticket is known by. run-triage.sh hands a KEY straight
  # through on GitHub-Issues boards; the other callers hand a numeric id.
  case "$tid" in
    ''|*[!0-9]*) keys="$tid" ;;
    *)
      if [ -s "$KEYMAP_FILE" ]; then
        keys=$(jq -r --arg t "$tid" '.[$t] // empty' "$KEYMAP_FILE" 2>/dev/null) || keys=""
      fi
      if [ -z "$keys" ]; then
        for p in "$HARNESS/plans/$PROJECT-"*"-$tid"; do
          [ -d "$p" ] || continue
          b="${p##*/}"; b="${b#"$PROJECT-"}"
          keys="${keys:+$keys
}$b"
        done
      fi ;;
  esac
  [ -n "$keys" ] || { cg_log "cannot evaluate $tid: no key"; echo "OK"; return 0; }

  while IFS= read -r key; do
    [ -n "$key" ] || continue
    mc_contested_wins "$PROJECT" "$key" && { echo "OK"; return 0; }
    pf="$HARNESS/plans/$PROJECT-$key/planned-files.txt"
    [ -s "$pf" ] && plans="${plans:+$plans
}$key	$pf"
  done <<<"$keys"
  if [ -z "$plans" ]; then
    cg_log "cannot evaluate $tid/$(printf '%s' "$keys" | tr '\n' ','): no planned-files list"
    echo "OK"; return 0
  fi

  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if ! mc_contested_live "$f"; then
      jq -e 'type=="object" and (.created|type=="number") and (.ttl|type=="number")' "$f" >/dev/null 2>&1 \
        || cg_log "malformed hold ${f##*/} ignored"
      continue   # a well-formed hold past its ttl is simply over
    fi
    hp=$(jq -r '.path // empty' "$f" 2>/dev/null) || hp=""
    w=$(jq -r '.winner_key // empty' "$f" 2>/dev/null) || w=""
    if [ -z "$hp" ] || [ -z "$w" ]; then
      cg_log "malformed hold ${f##*/} ignored"; continue
    fi
    while IFS=$'\t' read -r pkey pf; do
      [ -n "$pf" ] || continue
      while IFS= read -r want; do
        [ -n "$want" ] || continue
        # preplan_check's rule: a planned DIR covers the files under it.
        case "$hp" in
          "$want"|"$want"/*)
            cg_log "$tid/$pkey skipped: contested $hp (winner $w)"
            echo "BLOCKED contested=$hp winner=$w"; return 0 ;;
        esac
      done < "$pf"
    done <<<"$plans"
  done <<<"$holds"
  echo "OK"; return 0
}
# <<< contested-hold gate

# buildable_gate <ticket-id> -> OK | BLOCKED <reason>
#
# Fail-open: any fetch/parse problem prints OK, because blocking real work
# silently is worse than running one extra triage shard. GitHub-Issues boards
# have no waitingOn/triageVerdict, so they are always OK here.
# Reasons, in the order they are checked: dependencies (a board that serves the
# dependency primitive said `blocked: true` — keys named), waitingOn=client,
# triageVerdict=<verdict>, newest-comment-system.
# newest-comment-system has ONE exemption (BH-3970): the board OS writes its own
# `[AI Triage] …` verdict as the same internal system actor the harness writes
# with, so on its own that note read as our write and starved every ticket the
# board triaged. A newest comment whose first non-blank line starts with
# `[AI Triage]` on a ticket the board itself says is triageVerdict=ready AND
# waitingOn=team is not a reason to block. Anything else by that actor (a
# close-out, a note, a check-in) still is: that is the self-write guard.
buildable_gate() {
  local tid="${1:-}"
  [ -n "$tid" ] || { echo "OK"; return 0; }
  # Contested holds are local files, so this runs BEFORE the GitHub-Issues
  # early return below — those boards have holds too, they just have no
  # waitingOn/triageVerdict to fetch.
  local _cg; _cg=$(contested_gate "$tid")
  case "$_cg" in BLOCKED*) echo "$_cg"; return 0 ;; esac
  [ -n "${GH_ISSUES_REPO:-}" ] && { echo "OK"; return 0; }
  # The client-court guard reads a read it could not make as OK (fail-open, it
  # only decides whether to BUY a session). A launch must not: under
  # --buildable-strict every unanswerable read below is BLOCKED unreadable.
  local unread="OK"; [ "${BUILDABLE_STRICT:-0}" = 1 ] && unread="BLOCKED unreadable"
  local raw
  if [ -n "${JIRA_GATE:-}" ]; then
    # Jira (BH-4076): the adapter's read, in the shape board-fetch.sh returns.
    # A refused key or a partial thread is unreadable. An unanswered /myself
    # is not: the fields still decide, and only the newest-comment check that
    # needed it falls to $unread (ticket.ownUnknown, below).
    raw=$(trk_jira_gate_raw "$tid" 2>/dev/null) || { echo "$unread"; return 0; }
  else
    [ -n "$BASE" ] && [ -n "$TOKEN" ] && [ -n "$BP" ] || { echo "$unread"; return 0; }
    local since=""
    [ -e "$GATE" ] && since="$GATE"
    local fetch_args="$BASE$BP/tickets/$tid"
    [ -n "$since" ] && fetch_args="$fetch_args --since-file $since"
    raw=$(INTERNAL_TOKEN="$TOKEN" "$HARNESS/bin/board-fetch.sh" $fetch_args 2>/dev/null) || { echo "$unread"; return 0; }
  fi
  [ -n "$raw" ] || { echo "$unread"; return 0; }
  case "$raw" in
    "BOARD-FETCH FAILED:"*) echo "$unread"; return 0 ;;
  esac
  if [ "${BUILDABLE_STRICT:-0}" = 1 ] && ! printf '%s' "$raw" | jq -e 'type=="object"' >/dev/null 2>&1; then
    echo "$unread"; return 0
  fi

  # DEPENDENCIES FIRST (BH-815). A blocked ticket is not buildable whatever the
  # turn or the verdict says, and it is the one block that clears itself: the
  # board flips `blocked` when the last dependency lands. Reported ahead of the
  # waitingOn/verdict reasons so the line a human reads names the thing that is
  # actually holding the work.
  # Only a JSON boolean true blocks. A string "true", a null and an absent field
  # are all "this board has no dependency primitive", and any jq failure leaves
  # $b empty and falls through to the checks below — fail-open, as everywhere
  # else here.
  local b deps
  b=$(printf '%s' "$raw" | jq -r 'if (.blocked? | type) == "boolean" then .blocked
                                  elif (.ticket.blocked? | type) == "boolean" then .ticket.blocked
                                  else "" end' 2>/dev/null) || b=""
  if [ "$b" = "true" ]; then
    deps=$(printf '%s' "$raw" | jq -r '[((.dependsOn? // .ticket.dependsOn? // []) | .[]? | (.key // .id // empty | tostring))] | join(",")' 2>/dev/null) || deps=""
    echo "BLOCKED dependencies ${deps:-unlisted}"; return 0
  fi
  # >>> inapp deps buildable (BH-3946)
  # A board that served no `blocked` boolean has no dependency primitive, so
  # bin/lib/inapp-deps.sh reads the ticket's own `Blocked by` text instead. The
  # raw ticket goes through a FILE, never argv (MAX_ARG_STRLEN). A non-empty
  # first line is the answer; nothing, no lib, a failed temp file or
  # flags/inapp-deps-off falls through to the checks below, as today. The
  # function's rc never decides: a printed line is the answer either way.
  if [ -z "$b" ] && [ -z "${GH_ISSUES_REPO:-}" ] && [ -z "${JIRA_GATE:-}" ]; then
    for _P in "$(dirname "$0")/lib/inapp-deps.sh" "$HARNESS/bin/lib/inapp-deps.sh"; do
      # shellcheck source=/dev/null
      [ -r "$_P" ] && { . "$_P"; break; }
    done
    if declare -F inapp_deps_buildable >/dev/null 2>&1 && [ "$(inapp_deps_on "$HARNESS")" = 1 ]; then
      local _idf _ida=""
      _idf=$(mktemp "${TMPDIR:-/tmp}/inapp-deps-raw.XXXXXX" 2>/dev/null) || _idf=""
      if [ -n "$_idf" ] && printf '%s' "$raw" > "$_idf" 2>/dev/null; then
        # The whole output, whatever the rc: a printed answer is the answer
        # even when the function also returned nonzero, and no `head` means no
        # SIGPIPE status to erase it with.
        _ida=$(inapp_deps_buildable "$HARNESS" "$PROJECT" "$_idf" "${BUILDABLE_STRICT:-0}" 2>/dev/null) || true
        _ida=${_ida%%$'\n'*}
      fi
      [ -n "$_idf" ] && rm -f "$_idf"
      [ -n "$_ida" ] && { echo "$_ida"; return 0; }
    fi
  fi
  # <<< inapp deps buildable

  local w v
  w=$(printf '%s' "$raw" | jq -r '(.waitingOn? // .waiting_on? // .ticket.waitingOn? // .ticket.waiting_on? // "") | ascii_downcase' 2>/dev/null) || w=""
  v=$(printf '%s' "$raw" | jq -r '(.triageVerdict? // .triage_verdict? // .ticket.triageVerdict? // .ticket.triage_verdict? // "") | ascii_downcase' 2>/dev/null) || v=""

  if [ "$w" = "client" ]; then
    echo "BLOCKED waitingOn=client"; return 0
  fi
  if [ -n "$v" ] && [ "$v" != "ready" ]; then
    echo "BLOCKED triageVerdict=$v"; return 0
  fi

  local comments newest_name newest_uid newest_is_internal a newest_head board_verdict=0
  comments=$(printf '%s' "$raw" | jq -c '(.comments? // .ticket.comments? // .data.comments? // []) | sort_by(.createdAt // .created_at // "") | reverse' 2>/dev/null) || comments=""
  if [ -n "$comments" ] && [ "$(printf '%s' "$comments" | jq 'length' 2>/dev/null)" -gt 0 ]; then
    newest_name=$(printf '%s' "$comments" | jq -r '.[0].author.name? // .[0].author? // ""' 2>/dev/null)
    newest_uid=$(printf '%s' "$comments" | jq -r '.[0].author.userId? // ""' 2>/dev/null)
    newest_is_internal=$(printf '%s' "$comments" | jq -r '.[0].isInternal? // false' 2>/dev/null)
    # The board's own triage verdict (BH-3970, the doc above): first non-blank
    # line, left-trimmed, of whichever body field this board serves.
    if [ "$v" = "ready" ] && [ "$w" = "team" ]; then
      newest_head=$(printf '%s' "$comments" | jq -r '(.[0].body // .[0].content // .[0].text // "") | tostring
        | [splits("\n") | sub("^\\s+"; "") | select(. != "")] | .[0] // ""' 2>/dev/null) || newest_head=""
      case "$newest_head" in "[AI Triage]"*) board_verdict=1 ;; esac
    fi
    if [ "$newest_is_internal" = "true" ]; then
      [ "$board_verdict" = 1 ] || { echo "BLOCKED newest-comment-system"; return 0; }
    fi
    newest_name=$(printf '%s' "$newest_name" | tr '[:upper:]' '[:lower:]')
    newest_uid=$(printf '%s' "$newest_uid" | tr '[:upper:]' '[:lower:]')
    for a in $SELF_ACTORS; do
      a=$(printf '%s' "$a" | tr '[:upper:]' '[:lower:]')
      if [ "$newest_name" = "$a" ] || [ "$newest_uid" = "$a" ]; then
        [ "$board_verdict" = 1 ] || { echo "BLOCKED newest-comment-system"; return 0; }
      fi
    done
  fi
  # Jira: the token's own account was not resolved, so "the newest comment is
  # not ours" is unknown. Every check that could block has run already.
  if [ "$(printf '%s' "$raw" | jq -r '.ticket.ownUnknown? // false' 2>/dev/null)" = true ]; then
    echo "$unread"; return 0
  fi
  echo "OK"; return 0
}

if [ "$MODE" = "--buildable" ] || [ "$MODE" = "--buildable-strict" ]; then
  [ "$MODE" = "--buildable-strict" ] && BUILDABLE_STRICT=1
  TID="${3:-}"
  buildable_gate "$TID"
  exit 0
fi

# --signal <tid> (BH-2542): the SIGNAL digest of one ticket's whole thread —
# title, body, state and every comment that is not ours, hashed by
# bin/triage-signal.py. bin/lib/triage-signal.sh asks for it when a key's
# fingerprint moved, to tell a human change from our own bookkeeping. Prints 16
# hex chars or exits 1 with nothing: no creds, a failed or partial read (more
# than 300 GitHub comments), an unknown shape. Read-only: it takes no lock and
# writes no state, and it never prints a RUN/SKIP verdict.
# In-app, the caller's TRIAGE_SIGNAL_SELF_IDENTITIES (this project's identities
# row, resolved by bin/lib/triage-signal.sh, BH-2604) is handed to the digest.
# thread_doc <tid> (TRIAGE-STATE) — the ONE thread read both --signal and
# --thread make: prints {kind, self_actors, self_identities, self_apps, doc},
# where doc is {issue, comments} on a GitHub-Issues board and the raw
# `board-fetch.sh --full` body in-app, and the self fields are exactly what this
# gate resolved for the board. rc 1 with nothing on stdout on any failed or
# partial read (more than 300 GitHub comments included).
thread_doc() {
  local tid="${1:-}" n pg c sigd rc=0 apps
  command -v jq >/dev/null 2>&1 || return 1
  case "$tid" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  if [ -n "${GH_ISSUES_REPO:-}" ]; then
    command -v gh_rest >/dev/null 2>&1 || return 1
    if command -v _gh_rest_args_ok >/dev/null 2>&1; then _gh_rest_args_ok "$GH_ISSUES_REPO" || return 1; fi
    n=$(printf '%s' "$tid" | sed -E 's/^[A-Za-z]+-//')
    case "$n" in ''|*[!0-9]*) return 1 ;; esac
    sigd=$(mktemp -d) || return 1
    gh_rest GET "repos/$GH_ISSUES_REPO/issues/$n" > "$sigd/issue" || rc=1
    c=$(jq -r '.comments // 0' "$sigd/issue" 2>/dev/null) || rc=1
    case "$c" in ''|*[!0-9]*) rc=1 ;; *) [ "$c" -le 300 ] || rc=1 ;; esac
    pg=1
    while [ "$rc" = 0 ]; do
      gh_rest GET "repos/$GH_ISSUES_REPO/issues/$n/comments" -F per_page=100 -F page="$pg" > "$sigd/c$pg" || { rc=1; break; }
      c=$(jq -e 'if type == "array" then length else error end' "$sigd/c$pg" 2>/dev/null) || { rc=1; break; }
      [ "$c" -lt 100 ] && break
      pg=$((pg+1)); [ "$pg" -le 3 ] || rc=1   # a 4th page = more than 300 comments
    done
    apps='[]'; command -v harness_self_apps_json >/dev/null 2>&1 && apps=$(harness_self_apps_json)
    [ "$rc" = 0 ] && jq -cs --argjson apps "${apps:-[]}" \
      '{kind: "gh", self_actors: "", self_identities: "", self_apps: $apps, doc: {issue: .[0], comments: (.[1:] | add // [])}}' \
      "$sigd/issue" "$sigd"/c[0-9] 2>/dev/null || rc=1
    rm -rf "$sigd"
    return "$rc"
  fi
  [ -n "${BASE:-}" ] && [ -n "${TOKEN:-}" ] && [ -n "${BP:-}" ] || return 1
  INTERNAL_TOKEN="$TOKEN" "$HARNESS/bin/board-fetch.sh" "$BASE$BP/tickets/$tid" --full 2>/dev/null \
    | jq -c --arg sa "$SELF_ACTORS" --arg si "${TRIAGE_SIGNAL_SELF_IDENTITIES:-}" \
        '{kind: "inapp", self_actors: $sa, self_identities: $si, self_apps: [], doc: .}' 2>/dev/null
}
signal_digest() {
  local py doc kind
  py="$(dirname "$0")/triage-signal.py"; [ -r "$py" ] || py="$HARNESS/bin/triage-signal.py"
  [ -r "$py" ] && command -v jq >/dev/null 2>&1 || return 1
  doc=$(thread_doc "${1:-}") || return 1
  [ -n "$doc" ] || return 1
  kind=$(printf '%s' "$doc" | jq -r '.kind' 2>/dev/null) || return 1
  printf '%s' "$doc" | jq -c '.doc' 2>/dev/null \
    | SELF_ACTORS="$SELF_ACTORS" SELF_IDENTITIES="${TRIAGE_SIGNAL_SELF_IDENTITIES:-}" \
      SELF_APPS_JSON="$(printf '%s' "$doc" | jq -c '.self_apps' 2>/dev/null)" python3 "$py" --kind "$kind"
}
# --thread <tid> (TRIAGE-STATE): the wrapper thread_doc prints, for
# bin/lib/triage-state.sh's input hash. Read-only, like --signal: no lock, no
# state, never a RUN/SKIP verdict; exit 1 with nothing on a failed read.
if [ "$MODE" = "--thread" ]; then
  thread_doc "${3:-}" 2>/dev/null || exit 1
  exit 0
fi
if [ "$MODE" = "--signal" ]; then
  SIG=$(signal_digest "${3:-}" 2>/dev/null) || exit 1
  grep -qxE '[0-9a-f]{16}' <<<"$SIG" || exit 1
  printf '%s\n' "$SIG"
  exit 0
fi

if [ "$MODE" = "--seed" ]; then
  FP=$(fetch_fingerprint) || { echo "SEED-FAILED (gate will fail-open to RUN)"; exit 0; }
  printf '%s' "$FP" > "$GATE"
  date +%s > "$META"
  tgl_put_gate "$HARNESS" "$PROJECT"
  echo "SEEDED $(jq '[to_entries[] | select(.key != "meta") | .value | length] | add' <<<"$FP" 2>/dev/null || echo '?') tickets"
  exit 0
fi

# --pending (lever 5, 2026-08-21): fetch the live fingerprint into gate.pending
# WITHOUT making a run/skip decision. run-triage.sh uses this on queue/sweep
# ticks so their scoped sessions still see (and consume) any board changes that
# rode along — the gate's queue/sweep checks run BEFORE the board diff, so
# without this a scoped tick could starve a client's answer until the queue
# went quiet. Exit 0 only when the pending file was written; callers treat
# nonzero as "board state unknown, run with full context".
if [ "$MODE" = "--pending" ]; then
  FP=$(fetch_fingerprint) || exit 1
  printf '%s' "$FP" > "$PENDING"
  exit 0
fi

# 1. explicit force (flag file is one-shot)
if [ -f "$HARNESS/flags/force-triage-$PROJECT" ]; then rm -f "$HARNESS/flags/force-triage-$PROJECT"; echo "RUN forced"; exit 0; fi
[ "${FORCE_TRIAGE:-}" = "1" ] && { echo "RUN forced-env"; exit 0; }
# 1b. EVENT WAKE (bin/wake-loop.sh, docs/EVENTS.md) — a GitHub issue/comment
# delivery landed for this project since the last tick. ONE-SHOT, like the force
# flag above, and placed HERE deliberately: every brake below it is a cost brake
# that answers "the world has not changed since the last paid run", and a client
# comment IS the world changing. Without this the 45-minute queue brake could
# hold a client's answer for three quarters of an hour while the queue bytes
# stayed byte-identical. It does not launch a session — the gate still decides,
# a fingerprint diff still runs; it only stops the tick being braked past it.
# Absent file = today's behaviour exactly, so a fleet with no webhook installed
# never reaches this line.
if [ -f "$HARNESS/state/wake-$PROJECT" ]; then
  rm -f "$HARNESS/state/wake-$PROJECT"; echo "RUN event-wake"; exit 0
fi
# >>> split chain (BH-1655)
# 1c. A SPLIT SIBLING BECAME READY. On an in-app board a merged split child
# moves nothing the fingerprint carries (its status is `review`), and the queue
# PR-gate below only reads PR numbers written into READY-QUEUE lines — so the
# next sibling waited behind `SKIP no-change` indefinitely (project-3 TK-202,
# 2026-09-23). bin/lib/split-chain.sh reads this box's own build records and
# answers which open child now has every earlier sibling merged; a merged
# dependency IS the world changing, the same argument 1b makes for a webhook.
# Once per child per SPLIT_CHAIN_REMIND_S (its offered marker is written before
# this prints), so it cannot loop. GitHub-Issues boards keep
# bin/unblocked-children.sh; flags/split-chain-off, or no lib, is today exactly.
for _P in "$(dirname "$0")/lib/split-chain.sh" "$HARNESS/bin/lib/split-chain.sh"; do
  # shellcheck source=/dev/null
  [ -r "$_P" ] && { . "$_P"; break; }
done
if [ -z "${GH_ISSUES_REPO:-}" ] && command -v split_chain_gate >/dev/null 2>&1 && [ "$(split_chain_on "$HARNESS")" = 1 ]; then
  SC=$(split_chain_gate "$HARNESS" "$PROJECT" 2>/dev/null) || SC=""
  [ -n "$SC" ] && { echo "RUN split-ready"; exit 0; }
fi
# <<< split chain
# >>> gate reoffer (BH-3825)
# 1d. A PLAN_BLOCKED RESULT'S BLOCKER MERGED. A COMMENTED PLAN_BLOCKED result
# counts as settled, and the blocker merging moves nothing the fingerprint
# carries, so the blocked ticket waited behind `SKIP no-change` (project-4
# TK-2186, 2026-10-01). bin/gate-release.sh (run by rt_gate before this gate)
# stamps such keys into state/gate-reoffer-keys-<p> through
# bin/lib/gate-release/reoffer.sh, after writing each key's offered marker, so
# this fires at most once per key per GATE_RELEASE_REMIND_S. The gate only
# READS the file: the tick's scope consumes it (bin/lib/rt/scope.sh). A file
# older than the window is deleted unread. No file (the default: the scan is
# dark at GATE_RELEASE_MAX_LAUNCHES=0) is today exactly.
_GRK="$HARNESS/state/gate-reoffer-keys-$PROJECT"
if [ -z "${GH_ISSUES_REPO:-}" ] && [ -e "$_GRK" ]; then
  for _P in "$(dirname "$0")/lib/gate-release.sh" "$HARNESS/bin/lib/gate-release.sh"; do
    # shellcheck source=/dev/null
    [ -r "$_P" ] && { . "$_P"; break; }
  done
  _GRW=21600
  command -v _gr_knobs >/dev/null 2>&1 && _gr_knobs && _GRW="$_GR_REMIND"
  _GRT=$(stat -c %Y "$_GRK" 2>/dev/null || echo 0)
  if [ $(( $(date +%s) - _GRT )) -gt "$_GRW" ] 2>/dev/null; then
    rm -f "$_GRK"
  elif [ -s "$_GRK" ]; then
    echo "RUN gate-reoffer"; exit 0
  fi
fi
# <<< gate reoffer
# >>> inapp deps (BH-3946)
# 1e. A TEXT DEPENDENCY MERGED. An in-app ticket held by its own `Blocked by`
# lines (bin/lib/inapp-deps.sh) is released by a merge that moves nothing the
# fingerprint carries, the same gap 1c closes for split siblings.
# inapp_deps_gate answers the keys it released, and printing anything is the
# RUN; the tick's scope consumes state/inapp-deps-ready-<p> through
# inapp_deps_take_lines (bin/lib/rt/scope.sh). A ready file older than
# INAPP_DEPS_REMIND_S is deleted unread before the gate runs. GitHub-Issues
# boards keep bin/unblocked-children.sh; flags/inapp-deps-off, or no lib, is
# today exactly.
for _P in "$(dirname "$0")/lib/inapp-deps.sh" "$HARNESS/bin/lib/inapp-deps.sh"; do
  # shellcheck source=/dev/null
  [ -r "$_P" ] && { . "$_P"; break; }
done
if [ -z "${GH_ISSUES_REPO:-}" ] && declare -F inapp_deps_gate >/dev/null 2>&1 && [ "$(inapp_deps_on "$HARNESS")" = 1 ]; then
  _inapp_deps_knobs
  _IDR=$(inapp_deps_ready_file "$HARNESS" "$PROJECT") || _IDR=""
  if [ -n "$_IDR" ] && [ -e "$_IDR" ] \
     && [ $(( $(date +%s) - $(stat -c %Y "$_IDR" 2>/dev/null || echo 0) )) -gt "$INAPP_DEPS_REMIND_S" ]; then
    rm -f "$_IDR"
  fi
  _IDG=$(inapp_deps_gate "$HARNESS" "$PROJECT" 2>/dev/null) || _IDG=""
  [ -n "$_IDG" ] && { echo "RUN inapp-deps-ready"; exit 0; }
fi
# <<< inapp deps
# 1d. TRIAGE-STATE DEFERRED READS (BH-3921). An enforce pre-check that hit its
# read cap (or a low GitHub budget) listed the moved tickets it could not read
# in state/triage-state/<p>/deferred.keys and carried them as `skip
# deferred:*`, never to the model. Those keys are owed reads, the same argument
# 1b makes for a webhook: the brakes below answer "nothing changed since the
# last paid run", and these changed and were not read. A ts-deferred tick is
# $0 when the reads change nothing (ts_tick), and that $0 end never stamps the
# full-sweep clock. It never fires on a file older than a day, with a read cap
# of 0, on a GitHub board while the budget is low (no tick could drain it: the
# pre-check reads nothing and rewrites the same list, so every tick would be
# RUN ts-deferred and steps 2-4 would never run) or outside enforce (only
# enforce writes the list). The list stays: the first tick after the budget
# recovers drains it.
TS_DK="$HARNESS/state/triage-state/$PROJECT/deferred.keys"
if [ -s "$TS_DK" ] && [ $(( $(date +%s) - $(stat -c %Y "$TS_DK" 2>/dev/null || stat -f %m "$TS_DK" 2>/dev/null || echo 0) )) -lt 86400 ]; then
  if (
    for _P in "$(dirname "$0")/lib/triage-state.sh" "$HARNESS/bin/lib/triage-state.sh"; do
      # shellcheck source=/dev/null
      [ -r "$_P" ] && { . "$_P"; break; }
    done
    command -v _ts_knobs >/dev/null 2>&1 || exit 1
    _ts_knobs "$PROJECT"
    [ "$(ts_mode "$HARNESS" "$PROJECT")" = enforce ] && [ "$(_ts_int "${TRIAGE_STATE_MAX_FETCH:-30}" 30 0)" -gt 0 ] \
      && { [ -z "${GH_ISSUES_REPO:-}" ] || ! _ts_gh_budget_low; }
  ) >/dev/null 2>&1 </dev/null; then
    echo "RUN ts-deferred"; exit 0
  fi
fi
# 2. queued build work
# queue-pending COST BRAKE (2026-08-15, the operator): an unchanged queue re-triaged
# every 10 minutes concludes the same nothing at full session price (project-2 burned
# ~$2/tick for hours "still waiting on a merge"). Run only when the queue-side
# WORLD changed, else at most every 45 minutes. Deterministic: if these inputs
# are byte-identical, a fresh session cannot reach a different conclusion.
# rq_any, not a grep of the file: a `ready` ROW with no log line is real work,
# and a tick that cannot see it does nothing and says nothing (BH-1033).
if rq_any "$HARNESS" "$PROJECT"; then
  # RESULT listing is scoped to THIS project (2026-08-16 cost review): the old
  # builds/*/RESULT glob meant any other lane's build landing on the box reset
  # this project's 45m skip window — exactly on busy days, when ticks cost most.
  # READY-QUEUE.log is shared by every project on a multi-project box, so it is
  # hashed SCOPED to this project (rq_fp_file, BH-4120): another project's queue
  # churn must not re-offer this one. It stays whole-file, byte for byte, when
  # nothing in it is foreign — every single-project box hashes what it did.
  # Timestamp-normalized (2026-08-22, the $90/day project-1 loop): sessions
  # restamp "Re-checked <ts>" / "last probe <ts>" into READY-QUEUE.log on
  # every no-action tick, which changed this hash every 10 min and the 45m
  # skip never engaged. Strip ISO timestamps from the hash input — a restamp
  # is invisible, while any REAL change (status word, probe outcome, new
  # line) still reads as new-world.
  #
  # state/<project>.result-rows is the newest `result` ROW for this project,
  # published by bin/run-triage.sh (2026-09-11, project-3 TK-139). Every other input
  # here is a FILE on this box, and since a pool result stopped arriving by scp
  # and started arriving as a row, a finished build changed none of them — four
  # consecutive ticks skipped on `queue-unchanged` while an open PR waited for
  # its close-out. A new row is new-world exactly like a new queue line is.
  #
  # rq_fp is the ready ROWS' half of the same input, normalised the same way and
  # EMPTY while the flag is off — so this hash is byte-identical to what it was
  # until an operator turns the slice on, and a project does not buy a paid tick
  # just because a new input appeared.
  QFP=$( { rq_fp_file "$HARNESS" "$PROJECT" 2>/dev/null | sed -E 's/20[0-9]{2}-[0-9]{2}-[0-9]{2}[T ][0-9:.]{5,12}Z?//g'; rq_fp "$HARNESS" "$PROJECT" 2>/dev/null; ls "$HARNESS/state/build-queue/$PROJECT/" 2>/dev/null; ls -d "$HARNESS/builds/$PROJECT"-*/RESULT "$HARNESS/builds/pool-$PROJECT"-*/RESULT 2>/dev/null; cat "$HARNESS/state/$PROJECT.result-rows" 2>/dev/null; } | sha256sum | cut -c1-16)
  QFPF="$HARNESS/state/$PROJECT.queuefp"
  LASTQ=0; OLDQ=""
  [ -f "$QFPF" ] && { OLDQ=$(head -1 "$QFPF"); LASTQ=$(sed -n 2p "$QFPF"); }
  if [ "$QFP" = "$OLDQ" ] && [ $(( $(date +%s) - ${LASTQ:-0} )) -lt 2700 ]; then
    echo "SKIP queue-unchanged (recheck in $(( (2700 - $(date +%s) + ${LASTQ:-0}) / 60 ))m)"; exit 0
  fi
  # PR-gate verification (the operator 2026-08-21, deterministic-first): the 45m recheck
  # used to buy a full session that re-concluded "still waiting on PR #X" —
  # ~$1/tick, 5-6x/day on project-1. Whether a blocking PR merged is a FREE gh
  # lookup: extract every PR# the queue lines reference and compare their
  # open/merged/closed states to the vector stored at the last paid run. Same
  # states + same queue bytes = a fresh session cannot conclude differently, so
  # SKIP (hard 4h backstop still forces a run). Any lookup failure, no PR refs,
  # or no repo slug -> fail open to RUN exactly as before. Only .state is
  # compared — mergeStateStatus churns (BEHIND/UNKNOWN/CLEAN) without changing
  # what the session would do.
  if [ "$QFP" = "$OLDQ" ] && [ $(( $(date +%s) - ${LASTQ:-0} )) -lt 14400 ]; then
    SLUG=$("$HARNESS/bin/fleet-conf.sh" "$PROJECT" repo 2>/dev/null || true)
    PRNUMS=$(rq_lines "$HARNESS" "$PROJECT" 2>/dev/null | grep -oE 'PR ?#[0-9]+' | grep -oE '[0-9]+' | sort -un | head -20)
    PRV=""
    if [ -n "$SLUG" ] && [ -n "$PRNUMS" ]; then
      # THE SHARED BUDGET COMES FIRST (BH-1079). This loop is up to 20
      # lookups per project per tick, and under rate-limit exhaustion it was
      # competing with the lanes that MUST talk to GitHub. A low budget leaves
      # PRV empty, which is the branch this script already takes on any ERR: RUN
      # queue-pending with a 2-line queuefp, identical outcome, zero lookups.
      # A subshell because bin/lib/gh-budget.sh sets its own shell options and
      # resolves its root at source time; rc 1 (healthy) and rc 2 (unknown, or
      # no library) both proceed, like every other consumer.
      if ( [ -r "$HARNESS/bin/lib/gh-budget.sh" ] || exit 2
           # shellcheck source=bin/lib/gh-budget.sh
           . "$HARNESS/bin/lib/gh-budget.sh"; gh_budget_low triage-gate ); then
        PRV=""
      else
        # gh_rest_pr_state is a shell FUNCTION, so `timeout` cannot wrap it
        # without export -f; `gh api` carries its own network timeouts and the
        # loop is capped at 20 PRs by the head above.
        #
        # THE WORD IS UPPER-CASED BACK. gh_rest_pr_state answers lowercase
        # (open/merged/closed) where `gh pr view --json state` answered
        # OPEN/MERGED/CLOSED, and line 3 of this file is not private: BH-1015's
        # triage_prstates_ingest (bin/lib/triage-shards-lib.sh) folds this exact
        # vector into the per-ticket PR-state ledger verbatim, while its own
        # refresh pass writes the UPPER words. Leaving the API's spelling here
        # makes ingest and refresh disagree about the same PR, so the shard
        # fingerprint flips `open` <-> `OPEN` on every 45-minute cycle and buys a
        # paid session each way — which is the waste BH-1015 exists to remove.
        # One tr, and the two producers keep spelling the state the same.
        #
        # BH-1485: THE LOOP RUNS IN THIS SHELL. It used to be
        # `PRV=$(for n …; do printf … "$(gh_rest_pr_state …)"; done)` — two
        # nested command substitutions, so GH_REST_STATUS and GH_REST_REASON
        # were set in the inner subshell, read by nobody, and dead before the
        # outer one finished. The vector, the upper-casing and the `ERR`
        # poisoning below are unchanged; only the shell they happen in is.
        PRV=""; PRVST=""
        for n in $PRNUMS; do
          PRVST=""
          if gh_rest_pr_state_var PRVST "$SLUG" "$n" 2>/dev/null && [ -n "$PRVST" ]; then
            PRVST=$(printf '%s' "$PRVST" | tr '[:lower:]' '[:upper:]')
          else
            PRVST=ERR
          fi
          PRV="$PRV$n=$PRVST;"
        done
        case "$PRV" in *ERR*) PRV="";; esac
      fi
    fi
    OLDPRV=$(sed -n 3p "$QFPF" 2>/dev/null)
    if [ -n "$PRV" ] && [ "$PRV" = "$OLDPRV" ]; then
      echo "SKIP queue-gates-unchanged (${PRNUMS//$'\n'/,} all same state; hard recheck in $(( (14400 - $(date +%s) + ${LASTQ:-0}) / 60 ))m)"; exit 0
    fi
    printf '%s\n%s\n%s\n' "$QFP" "$(date +%s)" "$PRV" > "$QFPF"
    echo "RUN queue-pending"; exit 0
  fi
  printf '%s\n%s\n' "$QFP" "$(date +%s)" > "$QFPF"
  echo "RUN queue-pending"; exit 0
fi
# 3. finished builds awaiting their board close-out comment
SWEEP_HELD=0
for d in "$HARNESS/builds/$PROJECT"-*/ "$HARNESS/builds/pool-$PROJECT"-*/; do
  if [ -f "$d/RESULT" ] && [ ! -f "$d/COMMENTED" ]; then
    # results-sweep COST BRAKE: if the exact same un-commented set already got a
    # session <45m ago and is still un-commented, the session PROVED it cannot
    # close these (RESULT_UNVERIFIED etc.) — a re-run on identical input burns
    # money to prove it again. Skip until the set changes; the pipeline-health
    # cron alerts on the stuck set so it never rots silently.
    RFP=$(ls -d "$HARNESS/builds/$PROJECT"-*/RESULT "$HARNESS/builds/pool-$PROJECT"-*/RESULT 2>/dev/null | while read -r r; do [ -f "${r%RESULT}COMMENTED" ] || echo "$r"; done | sha256sum | cut -c1-16)
    RFPF="$HARNESS/state/$PROJECT.sweepfp"
    LASTR=0; OLDR=""
    [ -f "$RFPF" ] && { OLDR=$(head -1 "$RFPF"); LASTR=$(sed -n 2p "$RFPF"); }
    #
    # THE BRAKE HOLDS THE SWEEP, NOT THE BOARD (pool doctor, 2026-09-24). This
    # used to `exit` here, so steps 4-6 — the daily safety net and the board
    # diff — never ran while ANY result stayed un-commented. On box-
    # small the pool's account-exhaustion loop left ~300 dirs no sweep closes
    # (ledger-staged BUILD_DEFERRED, superseded QUEUED_FLY stubs), and from
    # 2026-09-23 19:03Z every cromford tick read sweep or sweep-unchanged:
    # no board-changed session for 16h, a run_triage command answered with a
    # skip, and 38 open ai-build tickets waiting. A stuck sweep set now only
    # stops us buying the SAME sweep again; a changed board still wakes the tick.
    if [ "$RFP" = "$OLDR" ] && [ $(( $(date +%s) - ${LASTR:-0} )) -lt 2700 ]; then
      SWEEP_HELD=1; break
    fi
    printf '%s\n%s\n' "$RFP" "$(date +%s)" > "$RFPF"
    echo "RUN results-sweep"; exit 0
  fi
done
# 3b. finished builds the LEDGER holds from another box that this box has not
# staged (BH-2350). bin/lib/rt/staging.sh pulls them at the top of the tick;
# this only wakes the tick, it stages nothing. "Not staged" is staging's own
# accounting: newer than its .since watermark (the same 50-row window it reads)
# and no .handled/<job>.job marker. Staged copies are named <p>-<KEY>-remote<ts>,
# never the ledger build_dir, so "no local dir" alone would wake for every
# remote row ever recorded. Own-box rows are never ours to pull, and without
# JOBS_BOX they cannot be told apart. rc 1 or 2 from bor_list: no change. The
# set is fingerprinted with sweepfp's 45-minute brake, and like that brake it
# holds the wake, not the board: a held set falls through to 4-6.
if command -v bor_list >/dev/null 2>&1 && [ -n "${JOBS_BOX:-}" ]; then
  RRD="$HARNESS/state/remote-results/$PROJECT"
  RSINCE=$(tr -dc '0-9A-Za-z:.-' < "$RRD/.since" 2>/dev/null)
  RMSET=""
  while IFS=$'\t' read -r RKEY RBDIR RBOX _U RLINE _PR RJOB; do
    [ -n "$RBDIR" ] && [ "$RBOX" != "$JOBS_BOX" ] || continue
    bor_local_dir "$RBDIR" >/dev/null && continue
    [ -f "$RRD/.handled/$RJOB.job" ] && continue
    RMSET="$RMSET$RKEY"$'\t'"$RLINE"$'\n'
  done < <(bor_list "$PROJECT" "$RSINCE" 50 2>/dev/null)
  if [ -n "$RMSET" ]; then
    RMFP=$(printf '%s' "$RMSET" | LC_ALL=C sort | sha256sum | cut -c1-16)
    RMFPF="$HARNESS/state/$PROJECT.remotefp"
    OLDRM=""; LASTRM=0
    [ -f "$RMFPF" ] && { OLDRM=$(head -1 "$RMFPF"); LASTRM=$(sed -n 2p "$RMFPF"); }
    case "$LASTRM" in ''|*[!0-9]*) LASTRM=0 ;; esac
    if [ "$RMFP" != "$OLDRM" ] || [ $(( $(date +%s) - LASTRM )) -ge 2700 ]; then
      printf '%s\n%s\n' "$RMFP" "$(date +%s)" > "$RMFPF"
      echo "RUN remote-results-pending"; exit 0
    fi
  fi
fi
# Every SKIP below says `sweep-unchanged` when the brake above held, so the
# project log reads exactly as it did on a tick that changes nothing.
skip_out() { if [ "$SWEEP_HELD" = 1 ]; then echo "SKIP sweep-unchanged"; else echo "SKIP $1"; fi; }
# 4. daily full-sweep safety net. A box with no gate-meta (moved project,
# rebuilt box) continues the project's clock from its ledger row (BH-2318).
[ -e "$META" ] || tgl_hydrate_meta "$HARNESS" "$PROJECT"
LAST=$(cat "$META" 2>/dev/null || echo 0)
case "$LAST" in ''|*[!0-9]*) LAST=0;; esac
[ $(( $(date +%s) - LAST )) -ge "$FULL_SWEEP_SECS" ] && { echo "RUN daily-sweep"; exit 0; }
# 5. no stored fingerprint yet -> must run. UNLESS the project's ledger row
# says which fingerprint was last consumed (BH-2318) and the live board hashes
# to it: then the live fingerprint IS that file, byte for byte, and it is
# written back. Any other answer (no row, flag off, outage, malformed row, a
# board that moved) is today's RUN, and no fetch is made without a row.
if [ ! -s "$GATE" ]; then
  tgl_read_gate "$HARNESS" "$PROJECT" || { echo "RUN no-gate-state"; exit 0; }
  FP=$(fetch_fingerprint) || { echo "RUN gate-fetch-failed"; exit 0; }
  tgl_hydrate_gate "$HARNESS" "$PROJECT" "$FP" "$TGL_SHA" || { echo "RUN no-gate-state"; exit 0; }
  skip_out "no-change ($(jq '[to_entries[] | select(.key != "meta") | .value | length] | add' <<<"$FP" 2>/dev/null || echo '?') tickets, gate restored from ledger)"
  exit 0
fi
# 6. board diff
FP=$(fetch_fingerprint) || { echo "RUN gate-fetch-failed"; exit 0; }
printf '%s' "$FP" > "$PENDING"
if [ "$(printf '%s' "$FP" | sha256sum | cut -d' ' -f1)" = "$(sha256sum < "$GATE" | cut -d' ' -f1)" ]; then
  rm -f "$PENDING"
  skip_out "no-change ($(jq '[to_entries[] | select(.key != "meta") | .value | length] | add' <<<"$FP" 2>/dev/null || echo '?') tickets)"
elif [ -n "${GH_ISSUES_REPO:-}" ] \
  && [ "$(jq -cS 'del(.meta)' <<<"$FP" 2>/dev/null | sha256sum | cut -d' ' -f1)" = "$(jq -cS 'del(.meta)' "$GATE" 2>/dev/null | sha256sum | cut -d' ' -f1)" ] \
  && jq -e 'type == "object" and has("issues")' "$GATE" >/dev/null 2>&1; then
  # ONLY THE CONTENT-HASH MAP MOVED (BH-2133 review). The issue and PR rows are
  # byte-identical, so nothing a session reads changed: the `meta` map moves
  # only alongside an updatedAt that the rows already carry, EXCEPT on the first
  # tick after the map shipped, when the consumed fingerprint has none. Store
  # the new shape and skip, rather than buy one full session per board for it.
  mv -f "$PENDING" "$GATE"
  tgl_put_gate "$HARNESS" "$PROJECT"
  skip_out "no-change ($(jq '[to_entries[] | select(.key != "meta") | .value | length] | add' <<<"$FP" 2>/dev/null || echo '?') tickets)"
else
  # Self-write absorption (cost lever 2, the operator 2026-08-07): if EVERY delta is a
  # system-actor comment bump (our own build close-outs, status notes), absorb
  # the fingerprint and skip — our writes were re-triggering a full session
  # every tick. Anything else, or any doubt, still runs. Fail-open.
  # GitHub-Issues lanes skip THIS absorption: they never set BASE/BP/TOKEN
  # (line 160 died on BASE under set -u) and the classifier can only fetch in-app
  # board comments. Their own absorption already happened inside
  # fetch_fingerprint (BH-2133, bin/lib/gate-self-comments.sh): a row that moved
  # only by Bot-authored comments arrives here with its consumed values, so
  # reaching this line means something other than our own notes moved. The PAT
  # login is never absorbed there — it is also the operator's hand.
  if [ -n "${GH_ISSUES_REPO:-}" ]; then
    echo "RUN board-changed"
    exit 0
  fi
  SWERR=$(mktemp 2>/dev/null) || SWERR=""
  VERDICT=$(GATE_OLD="$GATE" GATE_NEW="$PENDING" BASE="$BASE" BP="$BP" TOKEN="$TOKEN" \
    SELF_ACTORS="$SELF_ACTORS" python3 "$HARNESS/bin/gate-selfwrite.py" 2>"${SWERR:-/dev/null}" || echo RUN)
  # gate-selfwrite.py's stderr used to be appended to ALERTS.log raw; it is now one stamped line.
  if [ -n "$SWERR" ]; then
    [ -s "$SWERR" ] && "$HARNESS/bin/alert-line.sh" "[triage-gate] $PROJECT gate-selfwrite.py: $(tail -c 1500 "$SWERR")"
    rm -f "$SWERR"
  fi
  if [ "$VERDICT" = "ABSORB" ]; then
    mv -f "$PENDING" "$GATE"
    tgl_put_gate "$HARNESS" "$PROJECT"
    skip_out self-writes-only
  else
    echo "RUN board-changed"
  fi
fi
exit 0
