#!/bin/bash
# bin/lib/builder-direct.sh — the shared vocabulary of "the builder finishes its
# own job" (W2-B, the operator 2026-09-14: "4000 builder boxes submitting PRs all day;
# every throughput ceiling is a bug").
#
# THE FUNNEL THIS EXISTS TO REMOVE. A pool machine's build result came back to
# the HUB (bin/fly-results-ingest.sh -> state/remote-results/<p>/KEY.json), sat
# there until the owning box's next triage tick staged it, sat again until that
# session read the RESULT and posted the board comment, and only then did a
# 5-minute merge-conductor tick look at the PR. Three clocks and two machines
# stand between a finished build and a client hearing about it, and the hub is
# in the middle of every hop — at 4000 builders that is both the bottleneck and
# the single point of failure. The "remote-result unconsumed >30m" alerts in
# bin/pipeline-health.sh are that funnel backing up, seen from the side.
#
# The machine that built the thing already has the project env, the board token
# and the finished record. So it does the close-out itself: posts the board
# comment, moves the status, writes the terminal result straight to the jobs
# ledger, and rings the doorbell. The hub's ingest becomes bookkeeping.
#
# THE MARKER IS THE HAND-OFF, and it lives here so there is ONE definition of
# it. A close-out that has been posted must be visible to every OTHER path that
# could post a second one — the relay json, the ledger artifact feed, the hub's
# ingest — and the only thing all three spell identically is the FIRST LINE of
# the RESULT file (bin/run-triage.sh's own cross-path identity comment says the
# same thing, for the same reason). So a posted close-out appends a note there,
# and every reader asks bd_closed_out rather than growing its own grep.
#
# KILL FLAG: BUILDER_DIRECT=0 in the environment or env/global.env, or the
# builder-direct-off switch (BH-2435: the settings row
# switch.builder-direct-off[.<box>], then flags/builder-direct-off). Either one
# makes builder_direct_on answer 0, every
# caller skips its new path, nothing is appended to any RESULT line, and the
# relay path is byte for byte what it is today.
#
# Sourced, never executed. Safe under `set -u`. Nothing here logs, alerts, posts
# or writes: every function answers a question and the CALLER decides what that
# means.

# _bd_env <harness> <VAR> <default> -> the value
#   Environment first, then env/global.env, then the default. READS the env file
#   rather than sourcing it, exactly as bin/lib/preplan-lib.sh:_preplan_env and
#   bin/lib/build-caps.sh:build_slots do and for the same reason: the hub's
#   ingest asks this question without ever loading a project's secrets, and a
#   reporter must not inherit a box's environment to answer a yes/no.
_bd_env() {
  local h="${1:-}" var="${2:-}" def="${3:-}" v=""
  eval "v=\${$var:-}"
  if [ -z "$v" ] && [ -r "$h/env/global.env" ]; then
    v=$(sed -n "s/^[[:space:]]*\(export[[:space:]]\{1,\}\)\{0,1\}$var=//p" "$h/env/global.env" \
        | tr -d '"'"'"' \t' | tail -1)
  fi
  [ -n "$v" ] || v="$def"
  printf '%s\n' "$v"
}

# builder_direct_on [harness] -> 1 | 0     (DEFAULT 1 — the direct path is ON)
#   The FILE flag wins over the variable on purpose: a box in trouble is turned
#   off with a touch, by a medic who cannot edit env/global.env from where they
#   are standing.
builder_direct_on() {
  local h="${1:-${HARNESS:-/root/harness}}"
  # In a subshell, so lane-gate.sh and the jobs client never load into the
  # caller (bin/lib/rb/gates.sh branches on `command -v routing_builder`); and
  # through ls_isolated, so a client that exits when sourced answers from the
  # file instead of reading as "off" (the rc of a dead subshell is 1).
  if ( . "$h/bin/lib/lane-switch.sh" 2>/dev/null || ls_isolated() { [ -f "$h/flags/$2" ]; }
       HARNESS="$h" ls_isolated lane_switch builder-direct-off file ); then printf '0\n'; return 0; fi
  case "$(_bd_env "$h" BUILDER_DIRECT 1)" in
    0|off|no|false) printf '0\n' ;;
    *)              printf '1\n' ;;
  esac
}

# bd_marker -> the literal the RESULT line carries once a close-out is posted.
#   One definition. Callers that only need to TEST a line use bd_closed_out.
bd_marker() { printf 'CLOSED-OUT:'; }

# bd_note <where> -> the pipe-note appended to the RESULT line
#   Same shape the QA, migration, rebase and stacked notes already use, so the
#   line keeps its canonical prefix (bin/result-prefix-ok.sh) and every existing
#   grep in the fleet still matches it.
bd_note() { printf ' | %s the builder posted the board close-out on %s' "$(bd_marker)" "${1:-the board}"; }

# bd_closed_out <result-line> -> rc 0 when this build has already been closed out
#   by its own builder. THE ONE TEST, used by the hub's ingest and by the owning
#   box's staging: a dir whose RESULT says this is marked COMMENTED instead of
#   being handed to a session, because the second comment lands on a CLIENT's
#   ticket and there is no taking it back.
bd_closed_out() { case "${1:-}" in *"$(bd_marker)"*) return 0 ;; *) return 1 ;; esac; }

# bd_refusal_marker -> the literal a RESULT line carries when the builder's
#   close-out ran and did NOT post (BH-9879). It must never contain bd_marker's
#   text: a refusal read as "closed out" would lose the client's comment.
bd_refusal_marker() { printf 'CLOSEOUT-NOT-POSTED:'; }

# bd_refusal_note <rc> <stderr-file> -> ` | CLOSEOUT-NOT-POSTED: rc=<rc> <why>`
#   <why> is the last non-empty line of bin/board-closeout.sh's stderr, with
#   its say() prefix (`YYYY-MM-DD HH:MM:SSZ [closeout/<p>/<k>] `) stripped,
#   control characters and `|` removed, CLOSED-OUT spelled CLOSED_OUT, cut to
#   BUILDER_DIRECT_REASON_MAX characters. BH-9879: a pool machine's
#   pipeline.log is destroyed at reap, so the reason rides the RESULT line into
#   the job meta and the `result` artifact. Pure: it writes nothing.
bd_refusal_note() {
  local rc="${1:-}" f="${2:-}" why="" max
  # Fallback 160: settings row lib.builder-direct.BUILDER_DIRECT_REASON_MAX
  # (catalog/lanes.d/_lib.builder-direct.json).
  max="${BUILDER_DIRECT_REASON_MAX:-160}"
  case "$max" in ''|*[!0-9]*) max=160 ;; esac
  # Clamped to the row's min/max: lib_env_apply clamps only settings rows.
  max=$((10#$max)); [ "$max" -lt 40 ] && max=40; [ "$max" -gt 400 ] && max=400
  case "$rc" in ''|*[!0-9]*) rc="?" ;; esac
  [ -n "$f" ] && [ -r "$f" ] && why=$(tr -d '\r' < "$f" | grep -v '^[[:space:]]*$' | tail -1)
  why=$(printf '%s' "$why" \
    | sed -E 's/^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9:]{8}Z \[closeout\/[^]]*\] //' \
    | tr -d '|' | tr -d '[:cntrl:]' | sed 's/CLOSED-OUT/CLOSED_OUT/g')
  why="${why:0:$max}"
  [ -n "$why" ] || why="no reason on stderr"
  printf ' | %s rc=%s %s' "$(bd_refusal_marker)" "$rc" "$why"
}

# bd_facts <build-dir> [sha] [settled-tier] -> the terminal result as ONE compact
#   json object: { result, pr_url, sha, tier, verdict, cost_usd }
#
#   This is what goes to the ledger as the job's final word, and every field is
#   READ FROM THE RECORD rather than passed in by a caller that might be
#   describing a different build. An absent file gives an absent field, never a
#   guessed one: `tier` empty means nothing settled a tier, not tier 1.
#
#   THE SETTLED TIER OUTRANKS review.md, and a caller that knows it should pass
#   it. The reviewer writes `TIER: 1` before QA, the scope gate, the size gate,
#   the repair counter and the trust signal have run, and every one of those can
#   DEMOTE the build to tier 2. bin/run-build.sh holds the number those produced;
#   the file does not. Everything outside the build (fly/builder-runner.sh:305,
#   bin/fly-pool.sh, bin/fly-results-ingest.sh) can only read review.md, which is
#   why they get the fallback and not a guess.
bd_facts() {
  local b="${1:-}" sha="${2:-}" tier="${3:-}" line pr verdict cost
  [ -n "$b" ] && [ -s "$b/RESULT" ] || return 1
  line=$(head -1 "$b/RESULT" 2>/dev/null)
  pr=$(grep -oE 'https://github.com/[^ ]+/pull/[0-9]+' "$b/RESULT" 2>/dev/null | head -1)
  case "$tier" in 1|2) ;; *) tier=$(grep -oE '^TIER: [12]' "$b/review.md" 2>/dev/null | grep -oE '[12]' | tail -1) ;; esac
  # The one shared reader (BH-1625); unknown is an empty verdict, never APPROVE.
  command -v verdict_parse >/dev/null 2>&1 \
    || { [ -r "${BASH_SOURCE[0]%/*}/verdict-parse.sh" ] && . "${BASH_SOURCE[0]%/*}/verdict-parse.sh"; }
  verdict=$(verdict_parse -L "$b/review.md" 2>/dev/null) || verdict=""
  [ -n "$sha" ] || sha=$(head -1 "$b/reviewed-sha" 2>/dev/null | tr -dc '0-9a-f')
  # The same column bin/run-build.sh's COST_LINE sums, and the same silence when
  # there is no cost file: an unpriced build reports no cost, never $0.00.
  # $13, not $NF: cost_usd is column 13 and the row has grown past it three
  # times now (billing_mode, auth_fp/auth_account, then the session + attribution
  # columns on 2026-09-14). $NF is a position that moves; every one of these
  # readers meant cost_usd.
  [ -f "$b/cost.csv" ] && cost=$(awk -F, 'NR>1 {t+=$13} END {if (t>0) printf "%.4f", t}' "$b/cost.csv" 2>/dev/null)
  jq -nc --arg r "$line" --arg p "${pr:-}" --arg s "${sha:-}" --arg t "${tier:-}" \
         --arg v "${verdict:-}" --arg c "${cost:-}" \
    '{result:$r}
     + (if $p == "" then {} else {pr_url:$p} end)
     + (if $s == "" then {} else {sha:$s} end)
     + (if $t == "" then {} else {tier:$t} end)
     + (if $v == "" then {} else {verdict:$v} end)
     + (if $c == "" then {} else {cost_usd:($c|tonumber)} end)' 2>/dev/null
}

# bd_result_in_ledger <project> <key> <result-line> [machine-build-dir]
#   -> THREE ANSWERS, because
#   "the ledger says no" and "the ledger could not be asked" are different facts
#   with different remedies (BH-1041):
#
#     rc 0  the feed carries THIS BUILD's terminal result. The hub has nothing
#           to relay.
#     rc 1  the feed was READ and does not carry it. Relay, exactly as this hub
#           always has.
#     rc 2  it could not be ASKED at all: no jobs client in this shell, a
#           transport or HTTP failure, or an empty project/key.
#
#   WHICH BUILD, NOT WHICH TICKET (BH-1041 round-1 fix). Pass the machine build
#   dir — `basename $BUILD` on the builder, which is what bin/run-build.sh names
#   its row's detail.build_dir and what fly/builder-runner.sh writes as the
#   RESULT's `BUILD_DIR:` line — and the match is that build's own row. Without
#   it the only identity available is the ticket key, and a SECOND build of the
#   same key (a fix round, a re-dispatch) whose machine could not write its own
#   row reads as delivered on the FIRST build's row: rc 0, no relay, and the
#   ticket never hears the second result. With it that case is rc 1 and relays.
#
#   The key match survives as the FALLBACK, and only for a row that carries no
#   build_dir at all — rows written before 2026-09-10, which have no way to say
#   which build they are. A caller with no build dir in hand (there is no
#   BUILD_DIR: line on an older builder's RESULT) gets exactly today's
#   key-or-line match, so nothing regresses on the way in.
#
#   Reads back rather than assuming, exactly as bin/fly-pool.sh's reap does: the
#   artifact is written by run-build.sh ON THE MACHINE, so "the row is there" is
#   something the hub can only learn by asking.
#
#   WHY rc 2 EXISTS. Until BH-1041 rc 1 covered both of the last two and every
#   caller relayed on it, so a blink of the coordination DB pushed a copy of a
#   result whose row was already travelling — and the owning box staged the
#   build twice, which is two close-out comments on one client's ticket. Unknown
#   is not "absent", and a caller that cannot tell them apart has to guess.
#   What to DO about rc 2 is the caller's: bin/fly-results-ingest.sh leaves the
#   result on its builder for the next sweep, bin/fly-pool.sh parks it under a
#   RELAY_DEFERRED marker and re-asks each tick. Neither may map rc 2 to
#   "delivered" OR to "absent".
bd_result_in_ledger() {
  local p="${1:-}" k="${2:-}" line="${3:-}" mbd="${4:-}" feed
  [ -n "$p" ] && [ -n "$k" ] || return 2
  command -v job_artifact_feed >/dev/null 2>&1 || return 2
  feed=$(job_artifact_feed result "$p" "" 50 2>/dev/null) || return 2
  printf '%s\n' "$feed" | awk -F'\t' -v k="\"key\":\"$k\"" -v l="$line" -v b="$mbd" '
    NF>=6 {
      if (b != "" && index($6, "\"build_dir\":\"" b "\"")) { found=1 }
      else if (l != "" && $2 == l) { found=1 }
      else if (index($6, k) && (b == "" || index($6, "\"build_dir\":") == 0)) { found=1 }
    }
    END{exit !found}'
}
