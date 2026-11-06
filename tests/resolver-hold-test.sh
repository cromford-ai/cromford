#!/bin/bash
# tests/resolver-hold-test.sh — a human instruction on the ticket stops every
# rebuild path in bin/blocked-resolver.sh, and a later "resume" starts them again.
#
# WHY THIS IS THE TEST THAT MATTERS (console alert 6726, 2026-09-14). project-5
# #414's PR was CLOSED, the issue put on HOLD and de-labelled by the operator ("do not
# rebuild", 07:03Z) — and this lane enqueued a fresh build of it three times that
# morning (05:04, 06:44, 08:24Z). The rung that rebuilds a ticket read the PR and
# its own counters and never once read the ISSUE: not its state, not its labels,
# not its thread. So the assertions here are all about what the run DID: what it
# closed, what it enqueued, what it wrote to the state file — never about what the
# source says. A grep for `hold_check` in the script would pass on a version that
# calls it and ignores the answer.
#
# THE OTHER HALF IS THE LIFT. A hold that only a human can clear is a ticket
# parked for ever in a harness where nothing waits on a human (the operator, 2026-09-13),
# so the newest human comment wins in BOTH directions and the classifier's
# adversarial negatives ("do not resume this yet", "until the operator lifts the hold",
# a bot's own RESUME) carry as much weight as the happy path.
# Run from anywhere: tests/resolver-hold-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

# ONE clock read for the whole file (bin/test-determinism-lint.sh): every
# created_at below is derived from it, so the fixture thread is internally
# ordered whatever the wall clock says.
NOW=$(date -u +%s)
ISO() { date -u -d "@$((NOW - ${1:-0}))" '+%Y-%m-%dT%H:%M:%SZ'; }

H="$T/h"
mkdir -p "$H/bin/lib" "$H/logs" "$H/state" "$H/flags" "$H/locks" "$H/env" "$H/builds" \
         "$H/state/merge-conductor" "$H/state/build-queue/tproj" "$T/fakebin" "$T/repos"
cp "$DIR/bin/blocked-resolver.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/project-of.sh" \
   "$DIR/bin/box-for.sh" "$H/bin/"
# BH-1176: the lane sources bin/lib/br/ and REFUSES the tick when a module is
# missing, so the modules travel with the copy. One helper, one edit when the
# split moves again.
# shellcheck source=tests/lib/br-modules.sh
. "$DIR/tests/lib/br-modules.sh" || exit 1
br_modules_install "$DIR" "$H" || exit 1
cp "$DIR/bin/lib/gh-pr-list.sh" "$DIR/bin/lib/merge-conductor-lib.sh" \
   "$DIR/bin/lib/rebuild-ledger.sh" "$H/bin/lib/"
# bin/blocked-resolver.sh now REQUIRES the REST contract (#783): without it the
# lane refuses to start rather than deciding on undefined reads.
cp "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$H/bin/lib/"
mkdir -p "$H/bin/lib/mc" && cp "$DIR"/bin/lib/mc/*.sh "$H/bin/lib/mc/"
LIB="$H/bin/lib/hold.sh"
cp "$DIR/bin/lib/hold.sh" "$LIB" 2>/dev/null || true
# The fix round's push goes through it (BH-2504); absent on main, hence the || true.
cp "$DIR/bin/lib/hold-push.sh" "$H/bin/lib/" 2>/dev/null || true
chmod +x "$H/bin/"*.sh
# Two projects: tproj is a GitHub-Issues lane (board prefix "-"), iproj is an
# in-app product board, which has no GitHub issue to read (section 9).
{ printf 'tproj o/tproj - - 2 box-tproj 100.0.0.9\n'
  printf 'iproj o/iproj https://iproj.test /api/internal 3 box-iproj 100.0.0.8\n'; } > "$H/fleet.conf"
export FLEET_CONF="$H/fleet.conf"
# BH-1510.1: the resolver's models are model_routes rows; this worker-less box carries the resolver's cache of #1507's table.
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
mrs_fixture "$H" tproj iproj
: > "$H/env/global.env"
for f in beat.sh deploy-request.sh checks-run.sh pool-cap.sh; do
  printf '#!/bin/bash\nexit 0\n' > "$H/bin/$f"; chmod +x "$H/bin/$f"
done
# run-build.sh is the RESUME launch (section 8). Recorded, never run: "did the
# resume fire" is the whole question there.
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/run-build.txt"\nexit 0\n' "$T" > "$H/bin/run-build.sh"
# agent-call.sh is the adjudicator. Its answer goes in the OUT file (arg 5), the
# way bin/agent-call.sh writes it.
printf '#!/bin/bash\nprintf "ACCEPT\\n" > "$5"\nexit 0\n' > "$H/bin/agent-call.sh"
# lane-alert is RECORDED, never stubbed silent: a respected hold must not page,
# and "it went quiet" is only provable against a recorder.
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/lane-alert.txt"\nexit 0\n' "$T" > "$H/bin/lane-alert.sh"
chmod +x "$H/bin/run-build.sh" "$H/bin/agent-call.sh" "$H/bin/lane-alert.sh"

# Every gh call is recorded, so "did anything close a PR / reopen one / comment
# on the issue / read the issue at all" is a fact about the run.
# GH_ISSUE_FAIL=1 makes both ISSUE reads fail the way the real outage did.
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh.txt"
N=\$(printf '%s' "\$*" | sed -nE 's#.*/(pull|pulls|issues)/([0-9]+).*#\2#p' | head -1)
case "\$*" in
  # bin/blocked-resolver.sh decides over REST now (#783). This fixture names its
  # PR fields off the NUMBER in the path, so they are written where the shared
  # REST stub reads them and the envelope is answered there.
  *"-i -X "*)
    GHT="$T"
    printf 'ticket/ts-%s' "\$N" > "$T/prbranch"
    printf 'TK-%s: a thing' "\$N" > "$T/prtitle"
    printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' > "$T/prhead"
    . "$DIR/tests/lib/gh-rest-stub.sh"; gh_rest_stub "\$@" ;;
  *"issues/"*"/comments"*)
    [ "\${GH_ISSUE_FAIL:-}" = 1 ] && { echo "API rate limit already exceeded for user ID 2220366" >&2; exit 1; }
    cat "$T/comments-\$N.json" 2>/dev/null || echo '[]' ;;
  *"repos/"*"/issues/"*)
    [ "\${GH_ISSUE_FAIL:-}" = 1 ] && { echo "API rate limit already exceeded for user ID 2220366" >&2; exit 1; }
    cat "$T/issue-\$N.json" 2>/dev/null || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; } ;;
  *"pr close"*)   printf '%s\n' "\$*" >> "$T/closed.txt"; exit 0 ;;
  *"pr comment"*|*"issue comment"*) exit 0 ;;
  *"--json state"*)        cat "$T/prstate" 2>/dev/null || echo OPEN ;;
  # The resolver reads PR state over REST since BH-597 (one gh api
  # repos/O/R/pulls/N for the whole object). Same facts this stub has always
  # answered: the state from $T/prstate, the head sha and branch below it.
  "api repos/"*"/pulls/\$N")
    PST=\$(cat "$T/prstate" 2>/dev/null || echo OPEN)
    if [ "\$PST" = MERGED ]; then
      printf '{"number":%s,"html_url":"https://github.com/o/tproj/pull/%s","title":"t","body":"","state":"closed","merged_at":"2026-09-12T01:00:00Z","merge_commit_sha":"deadbeefcafe","mergeable_state":"clean","draft":false,"head":{"sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","ref":"ticket/ts-%s"},"base":{"ref":"main"},"user":{"login":"operator","type":"User"},"labels":[],"created_at":"2026-09-12T00:00:00Z","updated_at":"2026-09-12T01:00:00Z","closed_at":"2026-09-12T01:00:00Z"}\n' "\$N" "\$N" "\$N"
    else
      CL=null; [ "\$PST" = CLOSED ] && CL='"2026-09-12T01:00:00Z"'
      LOWST=\$(printf '%s' "\$PST" | tr 'A-Z' 'a-z')
      printf '{"number":%s,"html_url":"https://github.com/o/tproj/pull/%s","title":"t","body":"","state":"%s","merged_at":null,"merge_commit_sha":null,"mergeable_state":"clean","draft":false,"head":{"sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","ref":"ticket/ts-%s"},"base":{"ref":"main"},"user":{"login":"operator","type":"User"},"labels":[],"created_at":"2026-09-12T00:00:00Z","updated_at":"2026-09-12T00:00:00Z","closed_at":%s}\n' "\$N" "\$N" "\$LOWST" "\$N" "\$CL"
    fi ;;
  *"/pulls/"*)             echo "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ticket/ts-\$N" ;;
  *"--json headRefOid,headRefName"*) echo "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ticket/ts-\$N" ;;
  *"--json headRefName"*)  echo "ticket/ts-\$N" ;;
  *"--json headRefOid"*)   echo "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" ;;
  *"pr list"*"--state merged"*) cat "$T/mergedprs" 2>/dev/null ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
: > "$T/mergedprs"; : > "$T/gh.txt"; : > "$T/closed.txt"; : > "$T/queue.txt"
: > "$T/ssh.txt"; : > "$T/lane-alert.txt"; : > "$T/run-build.txt"
echo OPEN > "$T/prstate"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/flock"; chmod +x "$T/fakebin/flock"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/ssh.txt"\nexit 0\n' "$T" > "$T/fakebin/br-ssh"
chmod +x "$T/fakebin/br-ssh"
export PATH="$T/fakebin:$PATH"
# NO REAL CREDENTIAL REACHES THIS RUN (same rule as tests/blocked-resolver-test.sh).
export GH_TOKEN=""
# A jobs client whose queue_put is recorded rather than sent.
cat > "$H/bin/jobs-client.sh" <<EOF
queue_put() { printf '%s\n' "\$*" >> "$T/queue.txt"; echo queued; }
queue_done() { printf 'done %s\n' "\$*" >> "$T/queue.txt"; return 0; }
queue_list() { return 1; }
EOF
touch "$H/flags/fly-pool-tproj"   # pool project: the enqueue is a queue row

BRENV=()
RUN() { ( HARNESS="$H" FLEET_CONF="$H/fleet.conf" REPOS_ROOT="$T/repos" \
           BR_SSH="$T/fakebin/br-ssh" env ${BRENV[*]:+"${BRENV[@]}"} \
           bash "$H/bin/blocked-resolver.sh" "$@" >>"$T/run.log" 2>&1 ) || true; }
# The conductor hand-off row this lane drains: key, state, since, head, rev,
# alerted, why, url.
ROW() { printf '%s\tBLOCKED_HUMAN\t%s\t%s\t%s\t-\t%s\t%s\n' "$1" "$NOW" abc123 abc123 "$2" "$3" \
          > "$H/state/merge-conductor/pr-state.tsv"; }
ROWADD() { printf '%s\tBLOCKED_HUMAN\t%s\t%s\t%s\t-\t%s\t%s\n' "$1" "$NOW" abc123 abc123 "$2" "$3" \
          >> "$H/state/merge-conductor/pr-state.tsv"; }
STATEJSON() { cat "$H/state/blocked-resolver/tproj/$1.json" 2>/dev/null; }
CLEAN() { scratch_rm "$H/state/blocked-resolver"
          scratch_rm "$H/state/merge-conductor/handoff-released"
          : > "$T/closed.txt"; : > "$T/queue.txt"
          : > "$T/gh.txt"; : > "$T/ssh.txt"; : > "$T/lane-alert.txt"; : > "$T/run-build.txt"
          : > "$H/logs/blocked-resolver.log"; rm -f "$H/logs/ALERTS.log"; }

# --- the fixture issue and its thread ---------------------------------------
# ISSUE <state> <labels,csv> [title] [body]  -> the REST issue object
ISSUE() {
  local labels="[]"
  [ -n "${2:-}" ] && labels=$(printf '%s' "$2" | jq -Rc 'split(",")|map({name:.})')
  jq -nc --arg s "$1" --argjson l "$labels" --arg t "${3:-TK-9: the report rebuilt email}" \
         --arg b "${4:-## Scope}" --arg c "$(ISO 604800)" \
         '{number:9,state:$s,labels:$l,title:$t,body:$b,created_at:$c}'
}
# CMT <body> <age-seconds> [user-type] -> one REST comment
CMT() {
  jq -nc --arg b "$1" --arg c "${4:-$(ISO "${2:-0}")}" --arg u "${3:-User}" \
     '{body:$b,created_at:$c,user:{type:$u}}'
}
CMTS() { local IFS=","; printf '[%s]' "$*"; }   # join comments into the REST array
ISSUEFILE()   { printf '%s\n' "$2" > "$T/issue-$1.json"; }
COMMENTFILE() { printf '%s\n' "$2" > "$T/comments-$1.json"; }
# The normal shape: issue 9 open, ai-build labelled, nothing held.
OPEN_ISSUE=$(ISSUE open ai-build)
HELD_COMMENT=$(CMTS "$(CMT 'HOLD — the operator (2026-09-14 07:03Z): do not rebuild this.' 3600)")
board_clear() { ISSUEFILE 9 "$OPEN_ISSUE"; COMMENTFILE 9 '[]'; }
board_held()  { ISSUEFILE 9 "$OPEN_ISSUE"; COMMENTFILE 9 "$HELD_COMMENT"; }

# ============================================================================
# 1. hold_classify: the classifier, driven directly as the pure function it is.
#    Every adversarial row of the plan's invariant (c) is here, because this is
#    the function that decides whether an irreversible close+rebuild happens.
# ============================================================================
if [ -r "$LIB" ] && . "$LIB" 2>/dev/null; then ok; else bad "bin/lib/hold.sh is missing or does not source"; fi
classify() { # classify <issue-json> <comments-json> -> "<rc>|<verdict> <why>"
  command -v hold_classify >/dev/null 2>&1 || { printf '9|no hold_classify'; return; }
  local out rc
  out=$(hold_classify "$1" "$2" 2>/dev/null); rc=$?
  printf '%s|%s' "$rc" "$(printf '%s' "$out" | tr '\t' ' ')"
}
row() { # row <want-rc> <want-prefix> <issue> <comments> <label>
  local got; got=$(classify "$3" "$4")
  case "$got" in "$1|$2"*) ok ;; *) bad "$5 — wanted rc $1 '$2…', got '$got'" ;; esac
}
HOLDC=$(CMT 'HOLD — do not build this until the operator lifts the hold.' 7200)

# the structural answers, checked before the thread
row 1 "held closed"       "$(ISSUE closed ai-build)" '[]'                 "a CLOSED issue is held"
row 1 "held label-absent" "$(ISSUE open '')"         "$HELD_COMMENT"      "an issue with no ai-build label is held"
row 1 "held closed"       "$(ISSUE closed '')"       '[]'                 "closed is decided before the label"
# BH-2504: the `hold` label is a pause — state, so no RESUME lifts it, and it
# reads as the instruction (hold:label) even on a de-labelled ticket.
row 1 "held hold:label"   "$(ISSUE open ai-build,hold)" "$(CMTS "$(CMT RESUME 3600)")" "the hold label holds, and a RESUME does not lift it"
row 1 "held hold:label"   "$(ISSUE open hold)"       '[]'                 "the hold label is read before the ai-build label"
# the thread, by recency
row 0 "clear no-hold"     "$OPEN_ISSUE" '[]'                              "an open labelled issue with an empty thread is clear"
row 1 "held hold:comment" "$OPEN_ISSUE" "$(CMTS "$HOLDC")"                "the real #887 wording holds (and its 'lifts the hold' is not a lift)"
row 1 "held hold:comment" "$OPEN_ISSUE" "$(CMTS "$(CMT RESUME 7200)" "$(CMT 'HOLD — not yet' 3600)")" \
  "HOLD newer than RESUME holds"
row 0 "clear lifted-by-comment" "$OPEN_ISSUE" "$(CMTS "$(CMT 'HOLD — not yet' 7200)" "$(CMT RESUME 3600)")" \
  "RESUME newer than HOLD lifts"
row 1 "held hold:comment" "$OPEN_ISSUE" \
  "$(CMTS "$(CMT 'HOLD — not yet' 10800)" "$(CMT RESUME 7200)" "$(CMT 'HOLD again' 3600)")" \
  "HOLD then RESUME then HOLD is held"
row 1 "held hold:comment" "$OPEN_ISSUE" \
  "$(CMTS "$(CMT 'HOLD — not yet' 7200)" "$(CMT 'We rebuilt this ticket fresh against current main.' 3600)")" \
  "a neutral newer comment does not lift a HOLD"
# BH-3435: a lift word OPENING a person's comment lifts in any case, so a bare
# 'Resume' / 'resume' is now a lift (it used to be a negative below). Lower-case
# `resume` in harness prose mid-sentence still is not ("the resume lane's …").
for LIFT in 'Resume' 'resume'; do
  row 0 "clear lifted-by-comment" "$OPEN_ISSUE" \
    "$(CMTS "$(CMT 'HOLD — not yet' 7200)" "$(CMT "$LIFT" 3600)")" \
    "'$LIFT' opening a person's comment lifts a HOLD (BH-3435)"
done
# the negatives: none of these may lift the hold above them
for NEG in 'Do NOT RESUME this yet' 'still on HOLD' \
           "the resume lane's BUILD_DEAD is the reason" 'hold on, let me check' \
           'not lifting the hold yet' 'if the hold is lifted we can build'; do
  row 1 "held hold:comment" "$OPEN_ISSUE" \
    "$(CMTS "$(CMT 'HOLD — not yet' 7200)" "$(CMT "$NEG" 3600)")" \
    "'$NEG' must not lift a HOLD"
done
row 1 "held hold:comment" "$OPEN_ISSUE" \
  "$(CMTS "$(CMT 'HOLD — not yet' 7200)" "$(CMT RESUME 3600 Bot)")" \
  "a TK-authored RESUME must not lift a HOLD"
# an unparseable created_at can never be the newest word
row 1 "held hold:comment" "$OPEN_ISSUE" \
  "$(CMTS "$(CMT 'HOLD — not yet' 7200)" "$(CMT RESUME 0 User 'not-a-timestamp')")" \
  "a comment with an unreadable created_at sorts oldest"
# the lifts
for LIFT in 'RESUME' 'UNHOLD' 'HOLD lifted, go ahead' 'Lifting the hold, build it' \
            'hold is off' 'unhold please'; do
  row 0 "clear lifted-by-comment" "$OPEN_ISSUE" \
    "$(CMTS "$(CMT 'HOLD — not yet' 7200)" "$(CMT "$LIFT" 3600)")" \
    "'$LIFT' must lift a HOLD"
done
# words that are not the instruction
for NOTHOLD in 'the holder of the lock' 'HOLDER' 'HOLDING the release' 'putting a hold on nothing'; do
  row 0 "clear no-hold" "$OPEN_ISSUE" "$(CMTS "$(CMT "$NOTHOLD" 3600)")" \
    "'$NOTHOLD' must not hold the ticket"
done
row 0 "clear no-hold" "$OPEN_ISSUE" "$(CMTS "$(CMT 'HOLD — not yet' 3600 Bot)")" \
  "a TK-authored HOLD must not hold the ticket"
# the title and the body decide only when no comment does
row 1 "held hold:title" "$(ISSUE open ai-build 'Compliance P7 (HOLD): EU residency')" '[]' \
  "HOLD in the title holds (project-5 #14)"
row 1 "held hold:body" "$(ISSUE open ai-build 'TK-9: a thing' 'HOLD: until the client answers')" '[]' \
  "a HOLD: line in the body holds"
# ── BH-1461: A BODY HOLD IS AN EXPLICIT LINE, NEVER A WORD IN PROSE ──────────
# 2026-09-22: BH-1325, BH-1381 and BH-1419 were skipped by the pool every tick
# for four hours on `held hold:body`. None was held — each body MENTIONS the
# capital word while describing this very mechanism, and HOLD_WORD_RE matched it
# anywhere. A ticket about holds could never be built. The body now needs a LINE
# that begins with the instruction: `HOLD`, `HOLD:`, `HOLD —`.
#
# The three rows below are the three live bodies, cut to the line that held each
# one. They are the regression: if any of them reads `held` again, the incident
# is back.
row 0 "clear no-hold" "$(ISSUE open ai-build 'BH-1419: per-project pause' \
  '1. A per-project HOLD row for hub lanes: `harness-ctl off <hub-lane>`.')" '[]' \
  "BH-1419: 'a per-project HOLD row' in prose is not a hold"
row 0 "clear no-hold" "$(ISSUE open ai-build 'BH-1325: round-3 follow-ups' \
  'The PR shrank to the credential-logging hunks after the operator HOLD (\"rebase onto main\").')" '[]' \
  "BH-1325: 'the operator HOLD (...)' in prose is not a hold"
row 0 "clear no-hold" "$(ISSUE open ai-build 'BH-1381: conductor mode' \
  'two PUT /api/settings bodies with keys `merge-conductor.mode` and `merge-conductor.held_pages`; TRIAGE_CONDUCTOR_HOLD rc 0.')" '[]' \
  "BH-1381: HOLD inside a symbol name is not a hold"
# the shapes that DO hold: the word alone on its line, or opening one
row 1 "held hold:body" "$(ISSUE open ai-build 'TK-9: a thing' 'Scope follows.'$'\n''HOLD')" '[]' \
  "a line that is exactly HOLD holds"
row 1 "held hold:body" "$(ISSUE open ai-build 'TK-9: a thing' $'HOLD — waiting on the client\r\nrest of body')" '[]' \
  "a CRLF body whose first line opens with HOLD — holds"
row 1 "held hold:body" "$(ISSUE open ai-build 'TK-9: a thing' $'## Scope\r\nHOLD: until the client answers\r\n')" '[]' \
  "a HOLD: line mid-body holds, CRLF and all"
# ...and the shapes that must not, because the line does not BEGIN with it
for NOTBODY in 'HOLD until the client answers' '`HOLD:` is what pauses a lane' \
               '> HOLD: quoted from the other ticket' '| HOLD | pauses the lane |' \
               '    HOLD: inside an indented code block' 'see HOLD: above'; do
  row 0 "clear no-hold" "$(ISSUE open ai-build 'TK-9: a thing' "$NOTBODY")" '[]' \
    "a body line '$NOTBODY' must not hold the ticket"
done
# THE WHY NAMES THE LINE, which is what the pool's one-time comment repeats back
# to the author. A verdict that only says `hold:body` leaves them hunting.
case "$(classify "$(ISSUE open ai-build 'TK-9: a thing' $'## Scope\nHOLD: until the client answers')" '[]')" in
  *"HOLD: until the client answers"*) ok ;;
  *) bad "the body verdict must name the matched line, got '$(classify "$(ISSUE open ai-build 'TK-9: a thing' $'## Scope\nHOLD: until the client answers')" '[]')'" ;;
esac
case "$(classify "$OPEN_ISSUE" "$(CMTS "$(CMT 'HOLD — the operator: not until the client answers' 3600)")")" in
  *"HOLD — the operator: not until the client answers"*) ok ;;
  *) bad "a comment verdict must name the matched line" ;;
esac
# A RESUME still lifts a body hold, whichever shape wrote it.
row 0 "clear lifted-by-comment" "$(ISSUE open ai-build 'TK-9: a thing' 'HOLD: until the client answers')" \
  "$(CMTS "$(CMT RESUME 3600)")" "RESUME lifts a HOLD: body line"
row 0 "clear lifted-by-comment" "$(ISSUE open ai-build 'Compliance P7 (HOLD): EU residency')" \
  "$(CMTS "$(CMT RESUME 3600)")" "a RESUME comment is newer than the title and lifts it"
row 1 "held hold:title" "$(ISSUE open ai-build 'Compliance P7 (HOLD): EU residency')" \
  "$(CMTS "$(CMT 'looks right to me' 3600)")" "a neutral comment leaves a title HOLD standing"
# ── BH-1460: PAUSE AND ABANDON ARE DIFFERENT WORDS ──────────────────────────
# A HOLD stops automation and keeps the work; closing a PR is a different
# decision and needs a word of its own. Both still answer rc 1 — an abandon is
# also "do not build" — so anything reading only the rc is unaffected.
for AB in 'ABANDON' 'CLOSE-PR' 'ABANDON — this approach is wrong, close the PR'; do
  row 1 "held abandon:comment" "$OPEN_ISSUE" "$(CMTS "$(CMT "$AB" 3600)")" \
    "'$AB' asks for the PR to be closed"
done
# ...and the negation law applies to it exactly as it does to a lift.
for NOTAB in 'Do NOT ABANDON this yet' 'abandon' 'we should not abandon the approach' \
             'until we abandon this, keep going' 'the abandoned branch is still there'; do
  row 0 "clear no-hold" "$OPEN_ISSUE" "$(CMTS "$(CMT "$NOTAB" 3600)")" \
    "'$NOTAB' must not abandon the ticket"
done
row 0 "clear no-hold" "$OPEN_ISSUE" "$(CMTS "$(CMT ABANDON 3600 Bot)")" \
  "a TK-authored ABANDON must not abandon the ticket"
# THREAD ONLY. A body or a title that says ABANDON is prose about the word —
# BH-1461's lesson, applied before the incident rather than after it.
row 0 "clear no-hold" "$(ISSUE open ai-build 'TK-9: a thing' 'ABANDON: what the word does')" '[]' \
  "an ABANDON line in the BODY is not an abandon"
row 0 "clear no-hold" "$(ISSUE open ai-build 'How ABANDON closes a PR')" '[]' \
  "ABANDON in the TITLE is not an abandon"
# RECENCY, in both directions.
row 0 "clear lifted-by-comment" "$OPEN_ISSUE" \
  "$(CMTS "$(CMT ABANDON 7200)" "$(CMT RESUME 3600)")" "a newer RESUME lifts an ABANDON"
row 1 "held abandon:comment" "$OPEN_ISSUE" \
  "$(CMTS "$(CMT 'HOLD — not yet' 7200)" "$(CMT ABANDON 3600)")" "a newer ABANDON wins over a HOLD"
row 1 "held hold:comment" "$OPEN_ISSUE" \
  "$(CMTS "$(CMT ABANDON 7200)" "$(CMT 'HOLD — wait' 3600)")" "a newer HOLD wins over an ABANDON"
# The two predicates every caller reads the verdict with.
PAUSEV=$(hold_classify "$OPEN_ISSUE" "$(CMTS "$(CMT 'HOLD — not yet' 3600)")" 2>/dev/null)
ABV=$(hold_classify "$OPEN_ISSUE" "$(CMTS "$(CMT ABANDON 3600)")" 2>/dev/null)
if command -v hold_is_pause >/dev/null 2>&1 && command -v hold_is_abandon >/dev/null 2>&1; then
  hold_is_pause   "$PAUSEV" && ok || bad "hold_is_pause must be true for a HOLD verdict"
  hold_is_abandon "$PAUSEV" && bad "a HOLD verdict must not read as an abandon" || ok
  hold_is_abandon "$ABV"    && ok || bad "hold_is_abandon must be true for an ABANDON verdict"
  hold_is_pause   "$ABV"    && bad "an ABANDON verdict must not read as a pause" || ok
  hold_is_pause   "clear	no-hold" && bad "a clear verdict is not a pause" || ok
else
  bad "bin/lib/hold.sh must export hold_is_pause and hold_is_abandon"
  bad "(the second half of the same missing pair)"
  bad "(…and the third)"; bad "(…and the fourth)"; bad "(…and the fifth)"
fi
# A THREAD BIGGER THAN ARGV. A ticket that has been through a few harness rounds
# carries 60+ comments of 1-3 KB each, and a single argv string dies at 131072
# bytes (Linux MAX_ARG_STRLEN). Through `jq --argjson` such a thread answers
# NOTHING — which the caller reads as unreadable, on every tick, for ever: never
# rebuilt and never lifted. So the size is asserted first, and then the verdict.
BIGBODY=$(printf 'x%.0s' {1..2000})
BIGTHREAD=$(jq -nc --arg b "$BIGBODY" --arg c "$(ISO 7200)" --arg h 'HOLD — not yet' --arg hc "$(ISO 3600)" \
  '[range(0;70) | {body:$b,created_at:$c,user:{type:"User"}}] + [{body:$h,created_at:$hc,user:{type:"User"}}]')
[ "${#BIGTHREAD}" -gt 131072 ] && ok \
  || bad "the fixture thread must be over the 131072-byte argv limit to test anything (got ${#BIGTHREAD})"
row 1 "held hold:comment" "$OPEN_ISSUE" "$BIGTHREAD" \
  "a thread larger than the argv limit is still READ (and still held)"
row 0 "clear lifted-by-comment" "$OPEN_ISSUE" \
  "$(printf '%s' "$BIGTHREAD" | jq -c --arg c "$(ISO 60)" '. + [{body:"RESUME",created_at:$c,user:{type:"User"}}]')" \
  "…and its newest comment still decides"
# UNREADABLE is its own answer and is never "clear"
row 2 "unreadable" 'not json at all' '[]'      "an unparseable issue body is unreadable, not clear"
row 2 "unreadable" '{}' '[]'                    "an issue object with no state is unreadable, not clear"
row 2 "unreadable" "$OPEN_ISSUE" 'not json'     "an unparseable comments body is unreadable, not clear"

# ============================================================================
# 2. THE INCIDENT. A HOLD as the newest comment: nothing closed, nothing
#    enqueued, one respected line, the row parked HELD with no rung spent.
# ============================================================================
CLEAN
board_held
# A build record whose RESULT names this PR, so mc_record_for resolves it and
# the record-level marker has somewhere to land.
REC="$H/builds/tproj-TK-9-202609180001"
mkdir -p "$REC"
echo "PR_CREATED https://github.com/o/tproj/pull/9 TK-9" > "$REC/RESULT"
ROW "o/tproj#9" "merge-failed-twice: gh pr merge refused" "https://github.com/o/tproj/pull/9"
RUN
[ -s "$T/closed.txt" ] && bad "a held ticket's PR must NOT be closed (got: $(cat "$T/closed.txt"))" || ok
[ -s "$T/queue.txt" ]  && bad "a held ticket must NOT be enqueued (got: $(cat "$T/queue.txt"))" || ok
[ -s "$T/ssh.txt" ]    && bad "a held ticket must not have its re-offer marker cleared on the box" || ok
[ "$(grep -c '\[resolver\] HOLD respected TK-9' "$H/logs/blocked-resolver.log")" = 1 ] && ok \
  || bad "exactly one '[resolver] HOLD respected TK-9' line, got $(grep -c '\[resolver\] HOLD respected TK-9' "$H/logs/blocked-resolver.log")"
[ "$(STATEJSON tproj-TK-9 | jq -r .outcome)" = HELD ] && ok \
  || bad "the row must park HELD (got '$(STATEJSON tproj-TK-9 | jq -r .outcome)')"
[ "$(STATEJSON tproj-TK-9 | jq -r .rebuilds)" = 0 ] && ok \
  || bad "a respected hold must spend NO rung (rebuilds=$(STATEJSON tproj-TK-9 | jq -r .rebuilds))"
grep -qx 'held' <<<"$(STATEJSON tproj-TK-9 | jq -r '.attempts[].action')" && ok \
  || bad "the hold must be recorded as an attempt: $(STATEJSON tproj-TK-9 | jq -c '.attempts')"
[ -f "$REC/.blocked-resolver-held" ] && ok || bad "the build record must carry .blocked-resolver-held"
grep -q 'pr reopen' "$T/gh.txt" && bad "nothing may reopen a PR" || ok
grep -q 'pr close' "$T/gh.txt" && bad "nothing may close the PR" || ok
grep -q 'issue comment' "$T/gh.txt" && bad "a respected hold must not comment on the ticket" || ok
[ -s "$T/lane-alert.txt" ] && bad "a respected human instruction is not an alert: $(cat "$T/lane-alert.txt")" || ok
[ -s "$H/logs/ALERTS.log" ] && bad "a respected hold must write no ALERTS line" || ok
# A second tick is free and silent: the HELD row takes no rung and says nothing new.
RUN
[ "$(grep -c '\[resolver\] HOLD respected TK-9' "$H/logs/blocked-resolver.log")" = 1 ] && ok \
  || bad "a second tick must not write the respected line again"
[ -s "$T/queue.txt" ] && bad "a HELD row must never be enqueued on a later tick" || ok
[ "$(STATEJSON tproj-TK-9 | jq -r .rebuilds)" = 0 ] && ok || bad "a re-checked hold must still spend no rung"

# ============================================================================
# 2b. BH-1460. PAUSE KEEPS THE WORK; ABANDON IS WHAT THROWS IT AWAY.
#
#     2026-09-22: the lead put #1386 on HOLD to stop the resolver pushing to its
#     branch while the park on PR #1453 was adjudicated by hand, and twenty
#     minutes later that green, approved PR was closed and a person had to
#     reopen it. Whatever fired that close, the contract has to be unambiguous
#     and it has to be TESTED: a HOLD never touches an open PR, and a word that
#     does mean "close it" exists and says so on the PR.
# ============================================================================
CLEAN
board_held
REC2="$H/builds/tproj-TK-9-202609220001"
mkdir -p "$REC2"
echo "PR_CREATED https://github.com/o/tproj/pull/9 TK-9" > "$REC2/RESULT"
ROW "o/tproj#9" "merge-failed-twice: gh pr merge refused" "https://github.com/o/tproj/pull/9"
RUN
[ -s "$T/closed.txt" ] && bad "2b: a paused ticket's PR must NOT be closed (got: $(cat "$T/closed.txt"))" || ok
grep -q 'held, PR kept' "$H/logs/blocked-resolver.log" && ok \
  || bad "2b: the respected-hold line must say 'held, PR kept': $(grep 'HOLD respected' "$H/logs/blocked-resolver.log")"

# ...and the ABANDON word closes it, naming itself on the PR.
# THE INSTRUCTION CARRIES A BACKTICK (review round 1). The line a person typed
# is quoted back inside a backtick span, so one backtick of their own would
# close that span early and render the rest of their sentence as prose — in the
# one comment whose whole job is to quote them accurately. The fixture types the
# most ordinary thing there is, a command name in ticks, and the assertions
# below hold the span to exactly its own two.
CLEAN
ISSUEFILE 9 "$OPEN_ISSUE"
COMMENTFILE 9 "$(CMTS "$(CMT 'HOLD — not yet' 7200)" "$(CMT 'ABANDON — `npm test` was never going to pass, close it.' 3600)")"
: > "$T/comments.txt"; : > "$T/comment-bodies.txt"
ROW "o/tproj#9" "merge-failed-twice: gh pr merge refused" "https://github.com/o/tproj/pull/9"
RUN
[ -s "$T/closed.txt" ] && ok || bad "2b: an ABANDON must close the PR (closed.txt is empty)"
grep -q 'ABANDON' "$T/comment-bodies.txt" 2>/dev/null && ok \
  || bad "2b: the closing comment must name the word that did it: $(cat "$T/comment-bodies.txt" 2>/dev/null)"
QUOTED=$(grep 'The instruction read:' "$T/comment-bodies.txt" 2>/dev/null | head -1)
[ "$(grep -o '`' <<<"$QUOTED" | grep -c .)" = 2 ] && ok \
  || bad "2b: the quoted instruction must carry exactly the two backticks that ARE its span — got $(grep -o '`' <<<"$QUOTED" | grep -c .) in '$QUOTED'"
grep -q "npm test" <<<"$QUOTED" && ok \
  || bad "2b: ...and the person's words must survive the flattening: '$QUOTED'"
[ "$(STATEJSON tproj-TK-9 | jq -r .outcome)" = ABANDONED ] && ok \
  || bad "2b: the row must park ABANDONED (got '$(STATEJSON tproj-TK-9 | jq -r .outcome)')"
# The queue sink records both verbs, so "not enqueued" is about queue_put lines
# only — and the queue row must be CLOSED, or the pool re-offers the ticket the
# PR was just closed for.
grep -q . <<<"$(grep -v '^done ' "$T/queue.txt" 2>/dev/null)" \
  && bad "2b: an abandoned ticket must not be enqueued: $(cat "$T/queue.txt")" || ok
grep -q '^done .*failed' "$T/queue.txt" 2>/dev/null && ok \
  || bad "2b: the queue row must be closed failed, or the pool re-offers it: $(cat "$T/queue.txt")"
[ -s "$H/logs/ALERTS.log" ] && bad "2b: an obeyed ABANDON is an instruction, not an alert: $(cat "$H/logs/ALERTS.log")" || ok
# A second tick is silent: the terminal holds and nothing is closed twice.
: > "$T/closed.txt"
RUN
[ -s "$T/closed.txt" ] && bad "2b: a second tick must not close the PR again" || ok

# ============================================================================
# 3. The `ai-build` label was REMOVED — the fleet's "do not build this" gesture
#    (and what a decompose parent looks like). Structural, checked before any
#    comment.
# ============================================================================
CLEAN
ISSUEFILE 9 "$(ISSUE open '')"; COMMENTFILE 9 '[]'
ROW "o/tproj#9" "merge-failed-twice: gh pr merge refused" "https://github.com/o/tproj/pull/9"
RUN
[ -s "$T/closed.txt" ] && bad "a de-labelled issue's PR must not be closed" || ok
[ -s "$T/queue.txt" ]  && bad "a de-labelled issue must not be rebuilt" || ok
[ "$(STATEJSON tproj-TK-9 | jq -r .outcome)" = HELD ] && ok || bad "a de-labelled issue parks HELD"
grep -q 'label-absent' "$H/logs/blocked-resolver.log" && ok \
  || bad "the respected line must name label-absent: $(grep 'HOLD respected' "$H/logs/blocked-resolver.log")"

# ============================================================================
# 4. The ISSUE IS CLOSED. Somebody finished the ticket, or dropped it; either
#    way this lane does not reopen the question.
# ============================================================================
CLEAN
ISSUEFILE 9 "$(ISSUE closed ai-build)"; COMMENTFILE 9 '[]'
ROW "o/tproj#9" "merge-failed-twice: gh pr merge refused" "https://github.com/o/tproj/pull/9"
RUN
[ -s "$T/closed.txt" ] && bad "a closed issue's PR must not be closed by this lane" || ok
[ -s "$T/queue.txt" ]  && bad "a closed issue must not be rebuilt" || ok
[ "$(STATEJSON tproj-TK-9 | jq -r .outcome)" = HELD ] && ok || bad "a closed issue parks HELD"
grep -q 'HOLD respected TK-9 (closed' "$H/logs/blocked-resolver.log" && ok \
  || bad "the respected line must name closed: $(grep 'HOLD respected' "$H/logs/blocked-resolver.log")"

# ============================================================================
# 5. UNREADABLE IS NOT CLEAR, and it is not held either. The exact condition
#    this shipped under: both hub PATs are one GitHub user, the bucket ran out,
#    and a read that answered nothing must cost the ticket nothing.
# ============================================================================
CLEAN
board_clear
ROW "o/tproj#9" "merge-failed-twice: gh pr merge refused" "https://github.com/o/tproj/pull/9"
BRENV=(GH_ISSUE_FAIL=1)
RUN
BRENV=()
[ -s "$T/closed.txt" ] && bad "an unreadable issue must not have its PR closed" || ok
[ -s "$T/queue.txt" ]  && bad "an unreadable issue must not be rebuilt" || ok
[ "$(STATEJSON tproj-TK-9 | jq -r .outcome)" = "" ] && ok \
  || bad "an unreadable read must not park the row (got '$(STATEJSON tproj-TK-9 | jq -r .outcome)')"
[ "$(STATEJSON tproj-TK-9 | jq -r '.attempts[-1].action')" = hold-unreadable ] && ok \
  || bad "an unreadable read is recorded as hold-unreadable (got '$(STATEJSON tproj-TK-9 | jq -r '.attempts[-1].action')')"
[ "$(STATEJSON tproj-TK-9 | jq -r .rebuilds)" = 0 ] && ok || bad "an unreadable read must spend no rung"
grep -q 'API rate limit already exceeded' "$H/logs/blocked-resolver.log" && ok \
  || bad "the log must carry gh's own error: $(tail -3 "$H/logs/blocked-resolver.log")"
[ -e "$H/state/blocked-resolver/tproj/tproj-TK-9.hold-unreadable" ] && ok \
  || bad "the unreadable EPISODE must be marked, so the next tick knows it already said this"
# THE CONDUCTOR KEEPS ITS PARK. The rung never ran, so handing the PR back to be
# re-classified and re-parked every ten minutes buys churn over a question this
# box could not even ask.
[ -n "$(ls -A "$H/state/merge-conductor/handoff-released" 2>/dev/null)" ] \
  && bad "an unreadable read must not release the conductor hand-off" || ok
# ONE ATTEMPT PER EPISODE. This lane re-offers the same park every ten minutes,
# and an outage that lasts a day would otherwise write 144 entries into a record
# whose whole job is to say what was TRIED.
BRENV=(GH_ISSUE_FAIL=1)
RUN
BRENV=()
[ "$(STATEJSON tproj-TK-9 | jq '[.attempts[] | select(.action == "hold-unreadable")] | length')" = 1 ] && ok \
  || bad "a second failed read must not append a second hold-unreadable attempt: $(STATEJSON tproj-TK-9 | jq -c '.attempts')"
[ "$(grep -c 'hold check could not read o/tproj#9' "$H/logs/blocked-resolver.log")" = 2 ] && ok \
  || bad "…while the LOG still says it every tick (got $(grep -c 'hold check could not read o/tproj#9' "$H/logs/blocked-resolver.log"))"
# …and the moment gh answers again, with no hold, the rung runs as it always did.
RUN
grep -q '^tproj TK-9 9 fly 0 ' "$T/queue.txt" && ok \
  || bad "a readable, unheld issue must still be rebuilt (got: $(cat "$T/queue.txt"))"
[ -s "$T/closed.txt" ] && ok || bad "…and its stale PR closed (got: $(cat "$T/closed.txt"))"
[ -e "$H/state/blocked-resolver/tproj/tproj-TK-9.hold-unreadable" ] \
  && bad "a successful read must end the unreadable episode" || ok

# ============================================================================
# 5b. A FAILED READ MUST NOT ERASE A REBUILD THIS LANE IS WAITING ON.
#     br_from_rebuilds finds a build in flight by the last `rebuild-fresh`
#     attempt on the record. The hold gate writes attempts of its own without
#     spending a rung or starting anything, so they are read PAST — otherwise
#     one rate-limited tick drops the ticket out of that source for good and the
#     fresh build's outcome is never consumed (the project-5 #1645 shape).
# ============================================================================
CLEAN
: > "$H/state/merge-conductor/pr-state.tsv"
board_clear
mkdir -p "$H/state/blocked-resolver/tproj"
jq -nc --arg t1 "$(ISO 3600)" --arg t2 "$(ISO 1800)" \
  '{project:"tproj",rkey:"tproj-TK-11",first_seen:$t1,rebuilds:1,fixrounds:0,mechanicals:0,
    adjudications:0,rereviews:0,outcome:"",
    attempts:[{at:$t1,action:"rebuild-fresh",reason:"plan-malformed",detail:"fresh build enqueued"},
              {at:$t2,action:"hold-unreadable",reason:"plan-malformed",detail:"could not read o/tproj#11"}]}' \
  > "$H/state/blocked-resolver/tproj/tproj-TK-11.json"
REC11="$H/builds/tproj-TK-11-202609180011"
mkdir -p "$REC11"
echo "PR_CREATED https://github.com/o/tproj/pull/11 TK-11" > "$REC11/RESULT"
RUN
grep -qx 'rebuild-landed' <<<"$(jq -r '.attempts[].action' "$H/state/blocked-resolver/tproj/tproj-TK-11.json")" && ok \
  || bad "a rebuild in flight must still be seen after an unreadable read: $(jq -c '.attempts' "$H/state/blocked-resolver/tproj/tproj-TK-11.json")"
scratch_rm "$REC11"

# ============================================================================
# 6. THE LIFT, across runs. Nothing in this harness waits on a person to clear
#    state by hand: the resolver re-reads the issue on every tick and the ladder
#    resumes with its counters intact.
# ============================================================================
CLEAN
board_held
ROW "o/tproj#9" "merge-failed-twice: gh pr merge refused" "https://github.com/o/tproj/pull/9"
RUN
[ "$(STATEJSON tproj-TK-9 | jq -r .outcome)" = HELD ] && ok || bad "run 1 must park HELD"
COMMENTFILE 9 "$(CMTS "$(CMT 'HOLD — the operator: do not rebuild this.' 3600)" "$(CMT 'RESUME' 60)")"
RUN
[ "$(STATEJSON tproj-TK-9 | jq -r .outcome)" = "" ] && ok \
  || bad "a lifted hold must clear the terminal (got '$(STATEJSON tproj-TK-9 | jq -r .outcome)')"
grep -qx 'hold-lifted' <<<"$(STATEJSON tproj-TK-9 | jq -r '.attempts[].action')" && ok \
  || bad "the lift must be recorded: $(STATEJSON tproj-TK-9 | jq -c '.attempts')"
grep -q 'HOLD lifted on o/tproj#9' "$H/logs/blocked-resolver.log" && ok \
  || bad "the lift must write one line naming the issue"
grep -q '^tproj TK-9 9 fly 0 ' "$T/queue.txt" && ok \
  || bad "the lift must let the SAME tick rebuild (got: $(cat "$T/queue.txt"))"
# The close is a REST PATCH now (#783), so the line the stub records names
# repos/<slug>/pulls/9 rather than the old `gh pr close <url>` argv.
grep -q 'pulls/9' "$T/closed.txt" && ok || bad "the lift's rebuild must close the stale PR (got: $(cat "$T/closed.txt"))"
[ ! -f "$REC/.blocked-resolver-held" ] && ok || bad "the record's held marker must be removed when the hold lifts"
[ "$(STATEJSON tproj-TK-9 | jq -r .rebuilds)" = 1 ] && ok \
  || bad "the resumed ladder counts its first rebuild (got $(STATEJSON tproj-TK-9 | jq -r .rebuilds))"

# ============================================================================
# 7. A HELD ROW EATS NO SLOT. PER_TICK counts RUNGS, and a held candidate took
#    none — otherwise one held ticket at the top of the list starves the drain.
# ============================================================================
CLEAN
board_held
ISSUEFILE 10 "$(ISSUE open ai-build | jq -c '.number=10')"; COMMENTFILE 10 '[]'
ROW "o/tproj#9" "merge-failed-twice: gh pr merge refused" "https://github.com/o/tproj/pull/9"
RUN
[ "$(STATEJSON tproj-TK-9 | jq -r .outcome)" = HELD ] && ok || bad "candidate A must be HELD before the slot test"
: > "$T/queue.txt"; : > "$T/closed.txt"
ROWADD "o/tproj#10" "merge-failed-twice: gh pr merge refused" "https://github.com/o/tproj/pull/10"
BRENV=(BR_PER_TICK=1)
RUN
BRENV=()
grep -q '^tproj TK-10 10 fly 0 ' "$T/queue.txt" && ok \
  || bad "with one slot, a HELD first candidate must not stop the second (got: $(cat "$T/queue.txt"))"
grep -q '^tproj TK-9 ' "$T/queue.txt" && bad "the held candidate must still not be enqueued" || ok

# ============================================================================
# 8. THE OTHER (RE)START. A test-tamper block adjudicated ACCEPT restarts the
#    build — in place where the record can be resumed, and through the rebuild
#    rung otherwise — and BOTH of those are re-enqueues, so the same gate stands
#    in front of them.
#
#    WHAT THIS RUN ACTUALLY TAKES, and it is worth saying out loud: the in-place
#    resume branch is unreachable in production today. Its guard reads
#    `[ "${rec##*/pool-}" = "${rec##*/}" ]`, and for any ABSOLUTE record path the
#    left side is the whole path and the right side is the basename, so every
#    ACCEPT lands in the "pool copy, rebuild fresh" arm. That is a pre-existing
#    bug (not BH-408's, and deliberately not fixed here — fixing it would
#    silently switch every test-tamper ACCEPT from a rebuild to a resume); it is
#    named in the PR body. The gate sits in front of BOTH arms, and what is
#    asserted below is the outcome that matters either way: a held ticket is
#    neither resumed nor rebuilt.
# ============================================================================
CLEAN
scratch_rm "$REC"
: > "$H/state/merge-conductor/pr-state.tsv"
board_held
REC8="$H/builds/tproj-TK-9-202609180008"
mkdir -p "$REC8"
echo "REVIEW_BLOCKED test-tamper: two test cases removed" > "$REC8/RESULT"
echo "TICKET_ID: 9" >> "$REC8/RESULT"
echo "# the plan" > "$REC8/plan.md"
echo "removed: two cases" > "$REC8/test-tamper.txt"
: > "$REC8/.review-rescued"
touch -d '3 hours ago' "$REC8/RESULT"
RUN
[ -s "$T/run-build.txt" ] && bad "a held ticket must never be resumed (got: $(cat "$T/run-build.txt"))" || ok
[ -s "$T/queue.txt" ] && bad "…and never re-enqueued instead (got: $(cat "$T/queue.txt"))" || ok
grep -q 'ADJUDICATED ACCEPT' "$H/logs/blocked-resolver.log" && ok \
  || bad "the adjudication itself must still run — the gate refuses the RESTART, not the ruling"
[ "$(grep -c '\[resolver\] HOLD respected TK-9' "$H/logs/blocked-resolver.log")" = 1 ] && ok \
  || bad "the restart path must write the respected line exactly once"
[ "$(STATEJSON tproj-TK-9 | jq -r .outcome)" = HELD ] && ok || bad "the restart path parks HELD too"
[ -f "$REC8/.blocked-resolver-held" ] && ok || bad "the resumable record must carry .blocked-resolver-held"
# …and the record-level marker keeps it out of the candidate list even after the
# ladder's own state is gone — the twin of .blocked-resolver-abandoned.
scratch_rm "$H/state/blocked-resolver"
: > "$T/run-build.txt"; : > "$H/logs/blocked-resolver.log"
board_clear
RUN
[ -s "$T/run-build.txt" ] && bad "a record carrying .blocked-resolver-held must not be re-offered" || ok
[ -e "$H/state/blocked-resolver/tproj/tproj-TK-9.json" ] \
  && bad "…and nothing may be recorded against it" || ok
# …while the same record without the marker DOES restart: the gate is the only
# refusal on that path, and with the hold gone the ACCEPT restarts the build
# exactly as it did before this shipped.
CLEAN
rm -f "$REC8/.blocked-resolver-held" "$REC8/.blocked-resolver-superseded" "$REC8/COMMENTED"
board_clear
RUN
grep -q '^tproj TK-9 9 fly 0 ' "$T/queue.txt" && ok \
  || bad "an unheld test-tamper ACCEPT must still restart the build (queue: $(cat "$T/queue.txt"), resume: $(cat "$T/run-build.txt"))"
scratch_rm "$REC8"

# ============================================================================
# 9. AN IN-APP BOARD LANE HAS NO GITHUB ISSUE. The gate is a no-op there: it
#    reads nothing and the rung behaves exactly as it did before this shipped.
# ============================================================================
CLEAN
: > "$H/state/merge-conductor/pr-state.tsv"
ROW "o/iproj#9" "merge-failed-twice: gh pr merge refused" "https://github.com/o/iproj/pull/9"
# The box re-offer is the D1 `commented` row (bin/lib/comment-mark.sh, BH-2674):
# for this case only, the jobs client records ledger writes.
cp "$DIR/bin/lib/comment-mark.sh" "$H/bin/lib/" || exit 1
# The stub client is kept in a variable, not cp'd: tests/jobs-client-modules
# reads any `cp .../bin/jobs-client.sh` as a fixture install of the REAL client.
PRE9_CLIENT=$(cat "$H/bin/jobs-client.sh"); : > "$T/ledger.txt"
printf 'job_ledger_put() { printf "%%s\\n" "$*" >> %q; }\n' "$T/ledger.txt" >> "$H/bin/jobs-client.sh"
# The rebuild rungs read the in-app board's ticket status before rebuilding
# (BH-4438: done drops the rebuild, unreadable holds it), so this lane gets an
# internal token and a board that lists TK-9 as open — "as today" is an open
# ticket's rebuild. Both stubs exist for this section only.
printf '#!/bin/bash\necho token9\n' > "$H/bin/internal-token-for.sh"; chmod +x "$H/bin/internal-token-for.sh"
cat > "$T/fakebin/curl" <<'INNER'
#!/bin/bash
OUT=""; WANT=0; URL=""
while [ $# -gt 0 ]; do
  case "$1" in -o) OUT="$2"; shift 2 ;; -w) WANT=1; shift 2 ;; -H|-m) shift 2 ;; -*) shift ;; *) URL="$1"; shift ;; esac
done
case "$URL" in
  */boards/*/tickets) B='[{"id":"t9","key":"TK-9","number":9,"status":"review"}]' ;;
  */boards) B='[{"id":"b1"}]' ;;
  *) B="" ;;
esac
if [ -n "$OUT" ]; then printf '%s' "$B" > "$OUT"; else printf '%s\n' "$B"; fi
[ "$WANT" = 1 ] && printf '200'
exit 0
INNER
chmod +x "$T/fakebin/curl"
RUN iproj
rm -f "$T/fakebin/curl" "$H/bin/internal-token-for.sh"
# THE HOLD READ, which is hold_check's plain `gh api repos/<slug>/issues/<n>`.
# A PR comment posts to .../issues/<n>/comments over REST (#783) and is not a
# read of an issue at all, so the pattern names the read rather than the path.
grep -qE '^api (--paginate )?repos/[^ ]*/issues/[0-9]+' "$T/gh.txt" \
  && bad "an in-app lane must not read a GitHub issue: $(grep -E '^api (--paginate )?repos/[^ ]*/issues/' "$T/gh.txt")" || ok
[ -s "$T/closed.txt" ] && ok || bad "the in-app lane's rebuild must proceed as today (nothing closed)"
grep -q '^commented blocked iproj .* cleared' "$T/ledger.txt" && ok \
  || bad "…and its box must be told to re-offer the ticket through the commented row (ledger: $(cat "$T/ledger.txt"))"
[ -s "$T/ssh.txt" ] && bad "…never over ssh (BH-2674; ssh.txt: $(cat "$T/ssh.txt"))" || ok
printf '%s\n' "$PRE9_CLIENT" > "$H/bin/jobs-client.sh"

# ============================================================================
# 10. OBSERVE MODE says what it WOULD do and writes nothing.
# ============================================================================
CLEAN
: > "$H/state/merge-conductor/pr-state.tsv"
board_held
touch "$H/flags/blocked-resolver-observe"
ROW "o/tproj#9" "merge-failed-twice: gh pr merge refused" "https://github.com/o/tproj/pull/9"
RUN
rm -f "$H/flags/blocked-resolver-observe"
grep -q 'WOULD hold' "$H/logs/blocked-resolver.log" && ok \
  || bad "observe mode must say WOULD hold: $(tail -3 "$H/logs/blocked-resolver.log")"
[ -e "$H/state/blocked-resolver/tproj/tproj-TK-9.json" ] \
  && bad "observe mode must write no state" || ok
[ -s "$T/closed.txt" ] && bad "observe mode must close nothing" || ok
[ -s "$T/queue.txt" ]  && bad "observe mode must enqueue nothing" || ok

# ============================================================================
# 11. THE INCIDENT'S OWN SHAPE: a park whose PR IS ALREADY CLOSED. The conductor
#     has no row for it, so the build record is the only source that can re-offer
#     it — and it keeps doing so while the ladder's state says HELD, because a
#     hold nobody re-reads is a ticket nobody can un-park. Still held costs a
#     look and nothing else; a lift resumes the ladder with its counters intact.
# ============================================================================
CLEAN
: > "$H/state/merge-conductor/pr-state.tsv"
board_held
REC11H="$H/builds/tproj-TK-9-202609180011"
mkdir -p "$REC11H"
echo "PLAN_MALFORMED the plan had no VALIDATE line" > "$REC11H/RESULT"
touch -d '3 hours ago' "$REC11H/RESULT"
RUN
[ "$(STATEJSON tproj-TK-9 | jq -r .outcome)" = HELD ] && ok \
  || bad "a build-sourced park must respect the hold too (got '$(STATEJSON tproj-TK-9 | jq -r .outcome)')"
[ -f "$REC11H/.blocked-resolver-held" ] && ok || bad "…and mark its record held"
: > "$T/gh.txt"
RUN
grep -q 'issues/9' "$T/gh.txt" && ok \
  || bad "a HELD build record must be RE-READ on the next tick, not parked out of sight"
[ -s "$T/queue.txt" ] && bad "…and re-reading it must not rebuild it while the hold stands" || ok
[ "$(grep -c '\[resolver\] HOLD respected TK-9' "$H/logs/blocked-resolver.log")" = 1 ] && ok \
  || bad "…and must not repeat the respected line"
# The thread lifts it, and the ladder this record was on resumes in that tick.
board_clear
RUN
[ "$(STATEJSON tproj-TK-9 | jq -r .outcome)" = "" ] && ok \
  || bad "the lift must clear a build-sourced HELD row (got '$(STATEJSON tproj-TK-9 | jq -r .outcome)')"
grep -q '^tproj TK-9 9 fly 0 ' "$T/queue.txt" && ok \
  || bad "…and the rebuild it was holding must run (got: $(cat "$T/queue.txt"))"
[ ! -f "$REC11H/.blocked-resolver-held" ] && ok || bad "…and the record's marker must go with it"
scratch_rm "$REC11H"

# ============================================================================
# 12. BH-2504: EVERY RUNG READS THE TICKET, THE FIX ROUND INCLUDED.
#     2026-09-25: the lead held #2353 at 21:14:56Z and at 21:32:37Z this lane
#     logged `[reviews/review-changes-requested] -> fix-round` — the trigger was
#     the lead's own REQUEST_CHANGES — and pushed two commits onto the held
#     branch. br_hold_gate stood in front of the rebuild rungs only.
# ============================================================================
CLEAN
board_held   # the HOLD is an hour older than this dispatch
REC12="$H/builds/tproj-TK-9-202609250012"
mkdir -p "$REC12"
echo "PR_CREATED https://github.com/o/tproj/pull/9 TK-9" > "$REC12/RESULT"
ROW "o/tproj#9" "review-changes-requested: the lead's REQUEST_CHANGES on abc123" "https://github.com/o/tproj/pull/9"
RUN
grep -q -- '-> fix-round' "$H/logs/blocked-resolver.log" \
  && bad "12: a HOLD older than the dispatch must stop the review-changes-requested fix round before it is chosen: $(grep -- '-> fix-round' "$H/logs/blocked-resolver.log")" || ok
[ "$(grep -c '\[resolver\] HOLD respected TK-9' "$H/logs/blocked-resolver.log")" = 1 ] && ok \
  || bad "12: exactly one '[resolver] HOLD respected TK-9' line, got $(grep -c '\[resolver\] HOLD respected TK-9' "$H/logs/blocked-resolver.log")"
[ "$(STATEJSON tproj-TK-9 | jq -r .outcome)" = HELD ] && ok \
  || bad "12: the row must park HELD (got '$(STATEJSON tproj-TK-9 | jq -r .outcome)')"
[ "$(STATEJSON tproj-TK-9 | jq -r '.fixrounds // 0')" = 0 ] && ok \
  || bad "12: a held fix round must spend no rung (fixrounds=$(STATEJSON tproj-TK-9 | jq -r .fixrounds))"
[ -s "$T/closed.txt" ] && bad "12: a held ticket's PR must not be closed" || ok
# ...and the same park on a CLEAR ticket still reaches the fix round: the gate
# is a hold gate, not a wall.
CLEAN
board_clear
ROW "o/tproj#9" "review-changes-requested: the lead's REQUEST_CHANGES on abc123" "https://github.com/o/tproj/pull/9"
RUN
grep -q -- '-> fix-round' "$H/logs/blocked-resolver.log" && ok \
  || bad "12: a clear ticket's review-changes-requested park must still dispatch the fix round: $(tail -5 "$H/logs/blocked-resolver.log")"
scratch_rm "$REC12"

echo "resolver-hold: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
