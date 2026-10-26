#!/bin/bash
# bin/lib/preplan-lib.sh — the shared vocabulary of "is there already a plan for
# this ticket, and may it still be used".
#
# WHY A LIB (the operator, 2026-09-14). bin/run-preplan.sh has written plans into
# plans/<project>-<KEY>/ since 2026-07-23 and NOTHING EVER READ ONE: the PLAN
# checkpoint in bin/run-build.sh guards on $BUILD/plan.md, which a fresh build
# dir never has, so every pre-plan the fleet has ever paid for was thrown away
# and every build re-planned from scratch. Wiring the consumer means four files
# have to agree on the same facts — where a pre-plan lives, whether speculative
# mode is on, how many may run at once, and whether the plan is still true of
# main — and a second opinion on any of them is a build executing a plan for a
# file that has already moved. So they are functions here and the callers
# (bin/preplan-tick.sh, bin/preplan-candidates.sh, bin/run-preplan.sh,
# bin/run-build.sh) read them rather than each growing their own answer.
#
# Sourced, never executed. Safe under `set -u`. Nothing here logs, alerts or
# writes outside the pre-plan directory it is handed, except the settings cache
# and throttled logs/lane-gate.log lines lane_switch keeps when it reads a kill
# switch: every function answers a question and the CALLER decides what that
# means.

# The three kill switches below are read through lane_switch (BH-2443), which
# sources lane-gate.sh on first load. With no lib beside this one, the fallback
# answers exactly what the flag file answered.
# _preplan_root -> $HARNESS, else $H, else nothing (BH-2613 rule 1). Every
# [harness] argument below still wins over it. With no root the switches read
# as absent and no path is built (rule 2).
_preplan_root() { printf '%s' "${HARNESS:-${H:-}}"; }
# shellcheck source=lane-switch.sh
command -v lane_switch >/dev/null 2>&1 || . "${BASH_SOURCE[0]%/*}/lane-switch.sh" 2>/dev/null || lane_switch() { local r; r=$(_preplan_root); [ -n "$r" ] && [ -e "$r/flags/$1" ]; }

# _preplan_env <harness> <VAR> <default> -> the value
#   Environment first, then env/global.env, then the default. READS the env file
#   rather than sourcing it, for the same reason bin/lib/build-caps.sh:build_slots
#   does: bin/run-build.sh asks this question before it loads the fleet's env, and
#   a reporter must never inherit a box's secrets to answer an arithmetic one.
_preplan_env() {
  local h="${1:-}" var="${2:-}" def="${3:-}" v=""
  eval "v=\${$var:-}"
  if [ -z "$v" ] && [ -n "$h" ] && [ -r "$h/env/global.env" ]; then
    v=$(sed -n "s/^[[:space:]]*\(export[[:space:]]\{1,\}\)\{0,1\}$var=//p" "$h/env/global.env" \
        | tr -d '"'"'"' \t' | tail -1)
  fi
  [ -n "$v" ] || v="$def"
  printf '%s\n' "$v"
}

# preplan_speculative [harness] -> 1 | 0     (DEFAULT 1 — speculative is ON)
#
# THE KILL FLAG, and it has to be readable from three places that run at
# different moments, so it is one function. 0 restores 2026-07-23 behaviour
# exactly: one pre-plan at a time under locks/preplan.lock, the next queued
# ticket only, and no consumer at all in bin/run-build.sh.
#
# flags/preplan-speculative-off (or the `switch.preplan-speculative-off`
# settings row) is honoured beside the env var because an
# operator killing this at 3am should not have to edit env/global.env on every
# box — the same shape every other flag in flags/ has.
preplan_speculative() {
  local h="${1:-$(_preplan_root)}" v
  [ -n "$h" ] && HARNESS="$h" lane_switch preplan-speculative-off file && { printf '0\n'; return 0; }
  v=$(_preplan_env "$h" PREPLAN_SPECULATIVE 1)
  case "$v" in 0|no|off|false) printf '0\n' ;; *) printf '1\n' ;; esac
}

# preplan_ahead [harness]    -> how many UNTOUCHED ready tickets to pre-plan per
#                               project (default 2). 0 disables that class.
# preplan_parallel [harness] -> how many pre-plans may run at once box-wide
#                               (default 3). A plan is read-only and costs $1-2,
#                               so the cap is about session pressure, not money.
# Both floor at 0 and refuse non-numeric text rather than inventing a ceiling
# nobody set — an unreadable knob must never read as "unlimited".
preplan_ahead()    { local v; v=$(_preplan_env "${1:-$(_preplan_root)}" PREPLAN_AHEAD 2)
                     case "$v" in ''|*[!0-9]*) v=2 ;; esac; printf '%s\n' "$v"; }
preplan_parallel() { local v; v=$(_preplan_env "${1:-$(_preplan_root)}" PREPLAN_PARALLEL 3)
                     case "$v" in ''|*[!0-9]*) v=3 ;; esac; [ "$v" -lt 1 ] && v=1; printf '%s\n' "$v"; }

# overlap_schedule [harness] -> 1 | 0     (DEFAULT 1 — the schedule is ON)
#
# THE KILL FLAG for BH-475, and it is read from three places that run at
# different moments (bin/overlap-schedule.sh itself, the triage tick's feed,
# the reviewer's hot-file context in bin/run-build.sh), so it is one function
# for the same reason preplan_speculative is. 0 makes every one of those a
# no-op: the schedule prints nothing, the tick's prompt carries no section, and
# the launch-time defer in bin/run-build.sh is the sole gate again — which is
# byte-for-byte the behaviour before this change.
#
# flags/overlap-schedule-off (or the `switch.overlap-schedule-off` settings
# row) is honoured beside the env var because an operator
# killing this at 3am should not have to edit env/global.env on every box.
overlap_schedule() {
  local h="${1:-$(_preplan_root)}" v
  [ -n "$h" ] && HARNESS="$h" lane_switch overlap-schedule-off file && { printf '0\n'; return 0; }
  v=$(_preplan_env "$h" OVERLAP_SCHEDULE 1)
  case "$v" in 0|no|off|false) printf '0\n' ;; *) printf '1\n' ;; esac
}

# _preplan_env_isset <harness> <VAR> -> rc 0 when SOMEBODY set it on purpose
#   The difference between "the default happens to be 2" and "an operator wrote
#   2", which is the difference between a knob this code may raise and a
#   decision it must not overrule. Same two sources, same order, as _preplan_env.
_preplan_env_isset() {
  local h="${1:-}" var="${2:-}" v=""
  eval "v=\${$var:-}"
  [ -n "$v" ] && return 0
  [ -n "$h" ] && [ -r "$h/env/global.env" ] || return 1
  v=$(sed -n "s/^[[:space:]]*\(export[[:space:]]\{1,\}\)\{0,1\}$var=//p" "$h/env/global.env" \
      | tr -d '"'"'"' \t' | tail -1)
  [ -n "$v" ]
}

# preplan_ahead_ready [harness] -> how many untouched READY tickets to pre-plan
#                                  (default 10 with the schedule on, else
#                                  PREPLAN_AHEAD)
#
# TWO BOUNDS, NOT ONE (BH-475). PREPLAN_AHEAD=2 is the right number when a
# pre-plan is a latency optimisation for the next ticket or two the tick will
# pick up. It is the wrong number when the pre-plans ARE the input to
# bin/overlap-schedule.sh: a graph over 2 of 30 ready tickets cannot say which
# ones are independent, so the schedule degrades to "everything is UNPLANNED"
# and the launch-time 0m defer stays the only gate — the exact state this
# ticket exists to leave.
#
# SO IT IS A BIGGER NUMBER, NOT AN ABSENT ONE (BH-475 review). Every pre-plan is
# a paid model session and there is no per-key re-buy ledger yet, so "unbounded,
# up to gh's --limit 100" is a standing spend decision dressed as a default. The
# raise gets its own knob with a small documented default, and two things stay
# true that a raise must never quietly undo:
#   - an operator's EXPLICIT PREPLAN_AHEAD wins. A box that set 0 to control
#     spend keeps getting 0; a box that set 4 keeps getting 4. Only
#     PREPLAN_AHEAD_READY overrides that, because setting it is saying so.
#   - the per-tick spend is bounded where it always was, by PREPLAN_PARALLEL in
#     bin/preplan-tick.sh: more candidates means more TICKS, never more sessions
#     in one tick.
# The `blocked` class keeps preplan_ahead — a child of a parent nobody has
# started is not a ready ticket and its plan is the most speculative thing on
# the list.
preplan_ahead_ready() {
  local h="${1:-$(_preplan_root)}" v
  [ "$(overlap_schedule "$h")" = 1 ] || { preplan_ahead "$h"; return 0; }
  v=$(_preplan_env "$h" PREPLAN_AHEAD_READY "")
  case "$v" in ''|*[!0-9]*) v="" ;; esac
  [ -n "$v" ] && { printf '%s\n' "$v"; return 0; }
  _preplan_env_isset "$h" PREPLAN_AHEAD && { preplan_ahead "$h"; return 0; }
  printf '10\n'
}

# preplan_dir <harness> <project> <key> -> the hub's canonical path. No
#   existence check: bin/run-preplan.sh needs the name before the dir exists.
preplan_dir() { printf '%s/plans/%s-%s\n' "${1:-}" "${2:-}" "${3:-}"; }

# --- the attempt ledger: ok / empty / failed (BH-475 review) -----------------
#
# A PRE-PLAN IS A BILLABLE MODEL CALL, and until now the only thing it left
# behind was a plan. bin/run-preplan.sh's "produced no plan.md" path deleted the
# directory outright, so the next tick with a free slot bought the SAME key
# again — every ~10 minutes, for as long as it stayed in the ready set, with no
# cap and nothing on disk saying we had already paid. The fleet's metered-API
# rule (~/.claude/rules/metered-api-dedup.md) is three outcomes, and the check
# runs BEFORE the call, not after the charge:
#
#   ok      plan.md was written. preplan_check above owns that key from then on;
#           the attempt record is CLEARED, so a later failure starts from zero.
#   empty   the session exited 0 and produced no plan. It was billed and there
#           is genuinely nothing there (a refusal, an empty completion), so it
#           is TERMINAL — retrying it is how a guard becomes a loop.
#   failed  the session died (timeout, crash, non-zero exit). Retried to
#           preplan_max_attempts, then terminal.
#
# THE RECORD LIVES IN THE PRE-PLAN DIRECTORY, not in a second store: that
# directory already IS the persisted "have we paid for this key" ledger the
# freshness dedup reads, and a key whose answer lives in two places has two
# answers. A dir holding only these files is NOT a pre-plan — preplan_find
# requires plan.md — so nothing downstream can adopt one.
#
# HOW LONG IT LASTS, STATED EXACTLY. bin/preplan-tick.sh's housekeeping drops a
# plans/ dir older than 24h WHOSE KEY IS NOT ON READY-QUEUE.log. So for a
# speculative key the terminal state is a day long, not forever: a ticket whose
# body was clarified in the meantime gets another try tomorrow, and a
# permanently dead key costs one session a day instead of one every ten minutes.
# For a key that IS on the queue the sweep never fires and the record stands
# until the queue line goes — which is survivable, because that ticket's build
# writes its own plan in-build; the pre-plan it is refused is latency, not the
# plan it runs on. An operator who wants it re-tried sooner removes the
# directory (#1014 review: said plainly rather than implied away).

# preplan_rc_billed <rc> -> rc 1 when that agent-call rc is one a REFUSAL can
#                           exit with (nothing more — see preplan_billed)
#
# A CALL THAT NEVER HAPPENED IS NOT A FAILED ATTEMPT (#1014 review 2).
# bin/agent-call.sh's own header reserves these exit codes for refusals taken
# BEFORE any model call, with nothing called and nothing billed:
#   76  no account of the vendor had headroom (the claude/codex picker)
#   77  the hub runs no agent build work
#   78  a no-tools refusal
#   79  an argv-only lane refused the prompt, or a grok call was cliff-routed
#   75  documented as "a lock" in that header and kept here for the day
#       something produces it — nothing in bin/agent-call.sh returns 75 today.
#   74  the lane's own spend/pathway gate refused it (BH-1141): the lane is
#       disabled, the rung is outside LLM_RUNNER_ALLOWED, or the day's
#       LLM_USD_CAP_DAY is reached. An operator turning a lane off for an hour
#       must not cost every candidate key its attempts.
# Counting those against PREPLAN_MAX_ATTEMPTS turns a six-minute account outage
# into a day without pre-plans — three dry ticks and every candidate key is
# terminal — which is the opposite of what a spend guard is for.
preplan_rc_billed() {
  case "${1:-0}" in 74|75|76|77|78|79) return 1 ;; esac
  return 0
}

# preplan_cost_rows <harness> -> how many rows logs/cost.csv holds (0 if absent)
preplan_cost_rows() {
  local h="${1:-$(_preplan_root)}" n=""
  [ -n "$h" ] && n=$(wc -l < "$h/logs/cost.csv" 2>/dev/null | tr -d ' ')
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  printf '%s\n' "$n"
}

# preplan_billed <harness> <rc> <cost-rows-before> -> rc 0 when a session really
#                                                    ran and its outcome counts
#
# THE RC ALONE CANNOT ANSWER THIS (#1073 review). bin/agent-call.sh exits with
# the LAST RUNG's code (`exit "$RC"`, :2108), and the refusal codes belong to
# particular rungs — 76 to the claude/codex account picker, 79 to the grok
# cliff route. So a claude session that RAN, cost money and died (rc 1), then
# descended to a codex rung with no headroom, exits 76: the rc says "nothing
# was called" about a call that was billed. Skipping the record there is the
# runaway shape this whole change exists to stop, one layer down — no terminal
# state, re-bought every tick, no cap.
#
# So the rc is a necessary condition, never a sufficient one, and the evidence
# is the ledger agent-call itself writes: one logs/cost.csv row per attempt
# that ran (:1644), none for a refusal. Not billed means BOTH — a refusal code
# AND a cost file that did not grow. Anything else is a spent session.
#
# Fail-safe direction: an unreadable or missing cost.csv reads as "no growth",
# which only ever matters when the rc is already a refusal code, and on that
# path the cost of being wrong is one more retry rather than a lost record.
preplan_billed() {
  local h="${1:-$(_preplan_root)}" rc="${2:-0}" before="${3:-0}" after
  preplan_rc_billed "$rc" && return 0
  case "$before" in ''|*[!0-9]*) before=0 ;; esac
  after=$(preplan_cost_rows "$h")
  [ "$after" -gt "$before" ]
}

# preplan_max_attempts [harness] -> how many FAILED sessions a key may cost
#   (default 3). Floors at 1: a cap of 0 would read as "never pre-plan", which
#   is what PREPLAN_AHEAD=0 is for.
preplan_max_attempts() {
  local v; v=$(_preplan_env "${1:-$(_preplan_root)}" PREPLAN_MAX_ATTEMPTS 3)
  case "$v" in ''|*[!0-9]*) v=3 ;; esac; [ "$v" -lt 1 ] && v=1; printf '%s\n' "$v"
}

# preplan_attempt_record <plandir> <empty|failed> [prior-count] -> rc 0 written
#   Called on EVERY non-success exit of the lane. A path that writes nothing is
#   the bug this exists to close: with no record the dedup can never become
#   true and the next tick re-buys the same key.
#
#   PRIOR-COUNT EXISTS BECAUSE THE CALLER WIPES THE DIRECTORY FIRST. A planless
#   pre-plan dir must not survive looking adoptable, so bin/run-preplan.sh
#   removes it and then writes this record back — which means the count it is
#   continuing has to be read before the wipe and handed in. Left out, the
#   counter restarts at 1 every time and the cap never bites.
preplan_attempt_record() {
  local d="${1:-}" o="${2:-failed}" n="${3:-}"
  [ -n "$d" ] || return 1
  case "$o" in empty|failed) ;; *) o=failed ;; esac
  mkdir -p "$d" 2>/dev/null || return 1
  [ -n "$n" ] || n=$(cat "$d/attempts" 2>/dev/null)
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  printf '%s\n' "$((n + 1))" > "$d/attempts" 2>/dev/null || return 1
  printf '%s\n' "$o" > "$d/outcome" 2>/dev/null || return 1
}

# preplan_attempt_clear <plandir> — a plan landed, so the history is spent.
preplan_attempt_clear() {
  [ -n "${1:-}" ] && rm -f "$1/attempts" "$1/outcome" "$1/skip-logged" \
                           "$1/refusal-logged" 2>/dev/null
  return 0
}

# preplan_terminal <harness> <project> <key>
#   rc 0 + one line of reason when this key must NOT be pre-planned again;
#   rc 1 and nothing when it may be. A key with a plan.md is never terminal —
#   preplan_check owns it, and staleness is a different question.
preplan_terminal() {
  local h="${1:-}" p="${2:-}" k="${3:-}" d o n cap
  [ -n "$h" ] && [ -n "$p" ] && [ -n "$k" ] || return 1
  d=$(preplan_dir "$h" "$p" "$k")
  [ -s "$d/plan.md" ] && return 1
  o=$(cat "$d/outcome" 2>/dev/null)
  n=$(cat "$d/attempts" 2>/dev/null)
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  case "$o" in
    empty)
      printf 'a pre-plan session already ran for this key and returned no plan (billed, terminal)\n'
      return 0 ;;
    failed)
      cap=$(preplan_max_attempts "$h")
      if [ "$n" -ge "$cap" ]; then
        printf '%s failed pre-plan session(s), cap PREPLAN_MAX_ATTEMPTS=%s\n' "$n" "$cap"
        return 0
      fi ;;
  esac
  return 1
}

# preplan_find <harness> <project> <key> -> prints a directory holding a plan.md
#   for THIS key, rc 1 if there is none.
#
# THE RELAYED COPY IS CHECKED FIRST, because a fly builder has no hub state/ dir
# at all: bin/fly-pool.sh pushes the pre-plan beside the job file the same way it
# pushes the env bundle, and that copy is the only one the machine can see.
#
# The `key` file is not bookkeeping, it is the guard: a POOL MACHINE IS REUSED
# across jobs (fly-pool.sh:next_job_or_destroy), so a relay dir left by the
# previous ticket is sitting right there when the next one starts. Adopting it
# would hand build B the plan for ticket A — the same shape as TK-493, where a
# reused machine's alphabetically-first build dir was relayed home. So the
# directory must SAY which key it belongs to, and a mismatch is not a pre-plan.
preplan_find() {
  local h="${1:-}" p="${2:-}" k="${3:-}" relay d
  relay="${PREPLAN_RELAY_DIR:-/run/harness/preplan}"
  if [ -s "$relay/plan.md" ] && [ "$(cat "$relay/key" 2>/dev/null)" = "$k" ]; then
    printf '%s\n' "$relay"; return 0
  fi
  d=$(preplan_dir "$h" "$p" "$k")
  [ -s "$d/plan.md" ] && { printf '%s\n' "$d"; return 0; }
  return 1
}

# --- the box -> hub relay (BH-658) ------------------------------------------
# preplan_find above reads two DIRECTORIES, and neither of them exists on the
# hub: plans/<project>-<KEY>/ lives on the box that planned the ticket, and the
# hub is forbidden to plan (bin/lib/hub-box.sh). So bin/fly-pool.sh:push_preplan
# — which runs on the hub — was relaying a directory that is empty there by
# design, and every Fly build re-planned from scratch. The functions below are
# the missing hop: every box PUBLISHES the record it just wrote (whatever its
# routing flags say, BH-3437), the hub FETCHES it back into a directory of the
# same shape at dispatch, the builder fetches it again itself when that relay
# came too early (bin/lib/rb/plan.sh, BH-3437), and the overlap guard reads the
# same list the builder is about to be handed.
#
# FAIL-OPEN, like everything else that talks to the coordination DB: a refused
# or unreachable worker costs one PLAN stage, which is what today costs anyway.

# _preplan_client <harness> -> rc 0 when the jobs client's verbs are callable
#   here. Sourced lazily: bin/overlap-guard.sh and bin/fly-pool.sh already carry
#   the client, and a lib that sourced it eagerly would drag JOBS_* into every
#   caller of preplan_speculative.
_preplan_client() {
  local h="${1:-}"
  command -v preplan_get >/dev/null 2>&1 && return 0
  [ -r "$h/bin/jobs-client.sh" ] || return 1
  # shellcheck source=/dev/null
  . "$h/bin/jobs-client.sh" 2>/dev/null || return 1
  command -v preplan_get >/dev/null 2>&1
}

# preplan_fetch <harness> <project> <key> <dstdir>
#   Materialize a published pre-plan into <dstdir> in the EXACT shape
#   bin/run-preplan.sh leaves on disk, so everything downstream (push_preplan,
#   preplan_find, preplan_check) reads one layout.
#   rc 0 -> the five files are there;  rc 1 -> no such pre-plan (a real miss);
#   rc 2 -> the worker is unusable, or the row is not one this client can read.
#
#   `key` IS WRITTEN LAST and it is the gate: preplan_find refuses a directory
#   whose key does not match, so an interrupted fetch reads as "no pre-plan"
#   rather than as a pre-plan missing its staleness data.
#
#   A ROW FOR ANOTHER TICKET IS REFUSED outright. The worker filters, but the
#   directory must say who it is for anyway — a pool machine is reused between
#   jobs (TK-493), and "the server would not do that" is not a property the
#   machine holding the plan can check.
preplan_fetch() {
  local h="${1:-}" p="${2:-}" k="${3:-}" dst="${4:-}" row rc plan sha files fp ta
  [ -n "$h" ] && [ -n "$p" ] && [ -n "$k" ] && [ -n "$dst" ] || return 2
  command -v jq >/dev/null 2>&1 || return 2
  _preplan_client "$h" || return 2
  row=$(preplan_get "$p" "$k"); rc=$?
  case "$rc" in 0) ;; 2) return 1 ;; *) return 2 ;; esac
  [ "$(printf '%s' "$row" | jq -r '.ticket_key // ""' 2>/dev/null)" = "$k" ] || return 1
  plan=$(printf '%s' "$row" | jq -r '.plan_md // ""' 2>/dev/null)
  sha=$(printf '%s' "$row" | jq -r '.base_sha // ""' 2>/dev/null)
  [ -n "$plan" ] && [ -n "$sha" ] || return 2
  mkdir -p "$dst" 2>/dev/null || return 2
  # THE BYTE-CARRYING FIELDS ARE WRITTEN STRAIGHT OUT OF jq, never through a
  # $(…) capture: command substitution strips every trailing newline and the
  # printf below would put exactly one back, so a plan that ends in a blank line
  # — or in no newline at all — would be adopted as different bytes than the box
  # published. preplan_put ships the file with --rawfile (exact bytes), so the
  # round trip has to be exact too. base-sha/ticket-fp/key stay on printf: they
  # are single-line values whose readers compare or tr -d them.
  printf '%s' "$row" | jq -j '.plan_md // ""' > "$dst/plan.md" || return 2
  printf '%s\n' "$sha" > "$dst/base-sha" || return 2
  # Written ONLY when the row carries them: an empty planned-files.txt makes
  # preplan_check answer UNVERIFIABLE (which is discard), and an empty ticket-fp
  # would be a fingerprint that compares unequal to every real one.
  files=$(printf '%s' "$row" | jq -r '.planned_files // ""' 2>/dev/null)
  [ -n "$files" ] && { printf '%s' "$row" | jq -j '.planned_files // ""' > "$dst/planned-files.txt" || return 2; }
  fp=$(printf '%s' "$row" | jq -r '.ticket_fp // ""' 2>/dev/null)
  [ -n "$fp" ] && printf '%s\n' "$fp" > "$dst/ticket-fp"
  # BH-5799: the planner's thread stamp, so the plan thread gate judges this
  # plan against the comments newer than it. A row from before the column has
  # none, and bin/lib/plan-thread.sh:ptg_since then counts every comment.
  ta=$(printf '%s' "$row" | jq -r '.thread_at // ""' 2>/dev/null)
  if [ -n "$ta" ]; then printf '%s\n' "$ta" > "$dst/plan-thread-at"; else rm -f "$dst/plan-thread-at"; fi
  printf '%s\n' "$k" > "$dst/key" || return 2
  return 0
}

# preplan_planned_files <harness> <project> <key> -> the files this ticket's
#   pre-plan says it will touch, one per line. rc 1 and NOTHING printed when the
#   index answered and holds no list for the key; rc 2 and nothing printed when
#   it could not be asked (no jq, no jobs client, the index read failed). Both
#   must never read as "no overlap"; rc 2 lets a caller say WHY there is no list.
#
#   LOCAL DIRECTORY FIRST. On a watcher box that is the same file the builder
#   will adopt and the answer costs no request; only the hub, whose plans/ dir is
#   empty by design, ever reaches the row.
preplan_planned_files() {
  local h="${1:-}" p="${2:-}" k="${3:-}" f l
  [ -n "$h" ] && [ -n "$p" ] && [ -n "$k" ] || return 1
  f=$(preplan_dir "$h" "$p" "$k")/planned-files.txt
  [ -s "$f" ] && { cat "$f"; return 0; }
  command -v jq >/dev/null 2>&1 || return 2
  _preplan_client "$h" || return 2
  l=$(preplan_index "$p" 2>/dev/null) || return 2
  l=$(printf '%s\n' "$l" | awk -F'\t' -v k="$k" '$1==k {print $4; exit}')
  [ -n "$l" ] || return 1
  printf '%s\n' "$l" | tr '|' '\n' | sed '/^$/d'
}

# preplan_record <plandir> <repo> <baseref>
#   Everything the freshness check below will need, written next to the plan:
#   the sha the planner actually read, and the files the plan says it will touch
#   (bin/planned-files.sh, the same extractor the file-claim gate uses — one
#   parser, so "the files this plan owns" cannot mean two different sets).
preplan_record() {
  local d="${1:-}" repo="${2:-}" base="${3:-main}" sha
  [ -d "$d" ] || return 1
  sha=$(git -C "$repo" rev-parse "$base" 2>/dev/null) || return 1
  printf '%s\n' "$sha" > "$d/base-sha"
  "$(dirname "${BASH_SOURCE[0]}")/../planned-files.sh" "$d" 2>/dev/null || true
}

# preplan_check <plandir> <repo> <baseref> -> rc 0 FRESH | 1 STALE | 2 UNVERIFIABLE
#   Prints one line of reason on every path, because the caller logs it.
#
# THE RULE (the operator, 2026-09-14): a pre-plan made against base sha X is discarded if
# main has moved in ANY file the plan lists. Not "if main moved" — main moves
# constantly on a six-lane night and a plan for the billing page does not care
# that someone renamed a test. The intersection is the honest question, and
# bin/planned-files.sh deliberately over-lists, so this errs toward re-planning.
#
# UNVERIFIABLE IS DISCARD, NOT ACCEPT. No base sha, no file list, a shallow pool
# clone that cannot reach the sha — each of those means we cannot answer the
# question, and the cost of getting it wrong is asymmetric: re-planning costs
# 7-10 minutes and $1-2, executing a stale plan costs a wrong PR and a revert.
preplan_check() {
  local d="${1:-}" repo="${2:-}" base="${3:-main}" sha moved hits
  sha=$(cat "$d/base-sha" 2>/dev/null)
  case "$sha" in ''|*[!0-9a-f]*) printf 'no base sha recorded\n'; return 2 ;; esac
  [ -s "$d/planned-files.txt" ] || { printf 'no planned-files list\n'; return 2; }
  moved=$(git -C "$repo" diff --name-only "$sha" "$base" 2>/dev/null) || {
    printf 'base sha %s unreachable in this checkout\n' "${sha:0:8}"; return 2; }
  # grep -F -x against the plan's own list: a plan naming src/lib/pay.ts is stale
  # when that exact path moved, and a plan naming the DIRECTORY src/lib/pay is
  # stale when anything under it moved. Both spellings come out of
  # bin/planned-files.sh, so both are matched.
  hits=$(printf '%s\n' "$moved" | while IFS= read -r f; do
           [ -n "$f" ] || continue
           while IFS= read -r want; do
             [ -n "$want" ] || continue
             case "$f" in "$want"|"$want"/*) printf '%s\n' "$f"; break ;; esac
           done < "$d/planned-files.txt"
         done | sort -u | head -5 | tr '\n' ' ')
  if [ -n "$hits" ]; then
    printf 'main moved in planned files since %s: %s\n' "${sha:0:8}" "$hits"; return 1
  fi
  printf 'fresh against %s\n' "${sha:0:8}"; return 0
}

# preplan_base_ref <harness> <project> -> the ref a pre-plan is measured against
#   (default origin/main). Repos whose default branch is not main set
#   BASE_BRANCH in env/<project>.env — bin/run-build.sh:398 already reads it,
#   and a freshness check measured against the wrong branch would call every
#   pre-plan stale on those repos. Read, not sourced: see _preplan_env.
preplan_base_ref() {
  local h="${1:-}" p="${2:-}" b="${BASE_BRANCH:-}"
  if [ -z "$b" ] && [ -r "$h/env/$p.env" ]; then
    b=$(sed -n 's/^[[:space:]]*\(export[[:space:]]\{1,\}\)\{0,1\}BASE_BRANCH=//p' "$h/env/$p.env" \
        | tr -d '"'"'"' \t' | tail -1)
  fi
  [ -n "$b" ] || b=main
  printf 'origin/%s\n' "$b"
}

# preplan_key_prefix <harness> <project> -> the board KEY prefix, or nothing
#
# A GitHub-Issues project's harness KEY is <PREFIX>-<issue-number> (TK-493), and
# the ONLY place that prefix is written down is the rendered triage prompt —
# prompts/<project>.md carries the literal launch line bin/load-project.sh
# rendered from prompts/TEMPLATE-GH.md:
#   run-build.sh <project> <issue-number> <PREFIX>-<issue-number>
# fleet.conf has no column for it, so this reads it from there rather than
# inventing a second table that could disagree with the line triage actually
# runs.
#
# PRINTS NOTHING AND rc 1 when it cannot find one, and every caller must then
# do nothing: a pre-plan filed under a key the builder will never ask for is
# $1-2 spent into a directory nobody reads, which is precisely the silence this
# whole change exists to end.
#
# A JIRA OR LINEAR PROJECT (tracker_kind, bin/lib/tracker.sh, BH-7919) has its
# prefix in the tracker: the Linear team key or the Jira project key
# (tracker_key_prefix). Its prompt is never grepped, and no answer there is
# rc 1: a prompt line naming another prefix would file CRO-12's work as XX-12.
preplan_key_prefix() {
  local h="${1:-}" p="${2:-}" pfx kind=""
  if ! command -v tracker_kind >/dev/null 2>&1 && [ -n "$h" ] && [ -r "$h/bin/lib/tracker.sh" ]; then
    # shellcheck source=bin/lib/tracker.sh
    . "$h/bin/lib/tracker.sh" 2>/dev/null
  fi
  if command -v tracker_kind >/dev/null 2>&1 && HARNESS="$h" tracker_kind "$p" >/dev/null 2>&1; then
    kind=$(HARNESS="$h" tracker_kind "$p" 2>/dev/null) || kind=""
  fi
  case "$kind" in
    jira|linear)
      pfx=$(HARNESS="$h" tracker_key_prefix "$p" 2>/dev/null) || return 1
      [ -n "$pfx" ] || return 1
      printf '%s\n' "$pfx"
      return 0 ;;
  esac
  pfx=$(grep -ohE '\b[A-Z]{1,6}-<issue-number>' "$h/prompts/$p.md" 2>/dev/null | head -1 | cut -d- -f1)
  [ -n "$pfx" ] || return 1
  printf '%s\n' "$pfx"
}

# preplan_held <lockfile> -> rc 0 when some OTHER process holds this flock
#
# WHY NOT pgrep. The 2026-07-23 tick counted running pre-plans with
# `pgrep -f 'bin/run-preplan.sh'`, and a cmdline match is not a census: anything
# that merely MENTIONS the path counts — an agent session whose prompt names the
# script, a log tail, a shell history line. That reads as "pre-plans are already
# running" and the tick stands down having launched nothing, silently, which is
# the exact failure shape this whole change exists to end. The flock files are
# the harness's own statement of what is in flight (`locks/` is DEDUPE, the operator
# 2026-09-13), so they are what gets counted.
#
# Non-destructive: opening a lock file for write creates nothing that was not
# already there, and the subshell drops the descriptor immediately.
preplan_held() {
  local f="${1:-}"
  [ -e "$f" ] || return 1
  ( exec 9>"$f" || exit 0; flock -n 9 || exit 1 ) 2>/dev/null && return 1
  return 0
}

# preplan_midbuild_keys <harness> <project> -> the ticket KEYs this fleet is
#   BUILDING right now, one per line, sorted and deduped. Prints nothing and
#   returns 0 when it can see nothing — every source here is best-effort.
#
# WHY IT EXISTS (2026-09-16). bin/preplan-candidates.sh calls a blocker
# "clearing" when it is CLOSED or when some open PR already claims it, and a
# child of a clearing blocker is pre-planned. Both of those are facts about
# GITHUB, and they are both LATE: between the moment a parent's build starts and
# the moment its PR appears — 45 to 70 minutes on project-5 — the parent is
# neither closed nor claimed, so its children looked exactly like children of
# work nobody had started. They fell to the `blocked` class, which is bounded by
# PREPLAN_AHEAD and sits at the very bottom of the cap, so in a wave with more
# than a couple of them most were never planned at all.
#
# That is the hour bin/dep-verify.sh needed and did not get. Its file half reads
# the CHILD's planned-files list, and a child with no pre-plan is UNKNOWN, which
# every caller obeys exactly like a hard blocker — so a sibling that shares no
# file with its parent waited out the parent's whole build for want of a plan
# that costs $1-2 and is read-only. A parent that is MID-BUILD is the earliest
# honest signal that its children are coming, and this is that signal.
#
# THREE SOURCES, because no one of them sees the whole fleet:
#   build dir   this box's own disk. A build directory with no RESULT in it is a
#               pipeline that has not ENDED — RESULT is written on every ending,
#               so its absence is an event and not a stopwatch (the operator,
#               2026-09-16: no rule may turn on elapsed time).
#   build lock  locks/build-key-<project>-<KEY>.lock, HELD. The same flock
#               bin/run-build.sh takes for per-ticket dedupe, read the way
#               preplan_held reads every other lock here.
#   jobs ledger every OTHER box. A fly builder or a second watcher has no
#               directory and no lock on this machine; the ledger's `running`
#               rows are where its work is visible. One GET, and an outage
#               simply drops this source.
#
# FAIL-OPEN AND CHEAP: nothing here is an error, because the worst case is a
# plan that was not needed — the same $1-2 the `ahead` class spends every tick.
preplan_midbuild_keys() {
  local h="${1:-$(_preplan_root)}" p="${2:-}" d b k
  [ -n "$p" ] && [ -n "$h" ] || return 0
  {
    for d in "$h/builds/$p-"*/ "$h/builds/pool-$p-"*/ "$h/builds/fly-$p-"*/; do
      [ -d "$d" ] || continue
      [ -f "${d}RESULT" ] && continue
      b=${d%/}; b=${b##*/}; b=${b#pool-}; b=${b#fly-}; b=${b#"$p-"}
      k=$(printf '%s' "$b" | grep -oE '^[A-Z]+-[0-9A-Za-z]+' || true)
      [ -n "$k" ] && printf '%s\n' "$k"
    done
    for d in "$h/locks/build-key-$p-"*.lock; do
      [ -e "$d" ] || continue
      preplan_held "$d" || continue
      b=${d##*/}; b=${b%.lock}; b=${b#"build-key-$p-"}
      case "$b" in ''|*[!A-Za-z0-9._-]*) continue ;; esac
      printf '%s\n' "$b"
    done
    # `stale 0` is every OPEN row, not a stale one: the worker only applies the
    # age filter when the threshold is greater than zero (worker/jobs/src/index.js).
    # Columns are job_stale's: id, project, kind, stage, box, ticket_id, ...
    if [ -x "$h/bin/jobs-client.sh" ]; then
      "$h/bin/jobs-client.sh" stale 0 2>/dev/null \
        | awk -F'\t' -v p="$p" '$2==p && $3=="build" && $6!="" && $6!="-" {print $6}'
    fi
  } 2>/dev/null | sed '/^$/d' | sort -u
}

# --- the stale re-plan cap (BH-1016) -----------------------------------------
# WHY (Mac-side runaway-spend audit, 2026-09-17..19). preplan_check above is the
# honest freshness question, and bin/preplan-tick.sh acted on a STALE answer the
# only way it could: drop the directory and buy another plan. There was no
# ceiling on how often one ticket could do that, and the trigger is not the
# ticket at all — it is main moving in a file the plan happened to name. On a
# six-lane night every merge touching a shared file (prisma/schema.prisma,
# tests/lib/scratch.sh) re-bought a ~$4 Fable plan for every queued ticket that
# named it: project-4 paid for 152 stale re-plans on 2026-09-18 ($1,037 of pre-plan
# spend), TK-1847 about 50 in three days. Nothing errored; the bill was the only
# symptom.
#
# So the re-plan gets the shape ~/.claude/rules/metered-api-dedup.md requires of
# every metered call: a PERSISTED count, read BEFORE the session is launched,
# with a TERMINAL state written on the non-success exit rather than nothing at
# all. Past PREPLAN_STALE_MAX re-plans in 24h the key stops being re-planned and
# defers to the BUILD stage, which plans from scratch exactly as it did before
# pre-planning existed — so the cap costs latency, never correctness.
#
# TERMINAL IS NOT FOREVER, and it is keyed on the ticket rather than on the
# clock: a changed queue line (the ticket itself moved — new status, a new
# blocker, a re-scope) clears the marker and re-arms the full budget, and a
# marker that has aged out of the 24h window clears itself, so a ticket the
# fleet is still carrying tomorrow gets tomorrow's budget. Timestamps in the
# queue line are stripped before fingerprinting for the reason bin/triage-gate.sh
# strips them: sessions restamp `Re-checked <ts>` on every no-action tick, and a
# restamp that read as a changed ticket would clear every marker every hour and
# the cap would never bite.

# preplan_stale_max [harness] -> how many STALE re-plans one ticket may buy
#   inside the 24h window (default 2). 0 disables stale re-planning entirely —
#   the first stale answer defers to the build stage. Non-numeric text falls
#   back to the default: an unreadable knob must never read as "unlimited".
preplan_stale_max() {
  local v; v=$(_preplan_env "${1:-$(_preplan_root)}" PREPLAN_STALE_MAX 2)
  case "$v" in ''|*[!0-9]*) v=2 ;; esac
  printf '%s\n' "$v"
}

# _preplan_state <harness> -> the ledger directory, created on demand. rc 1 when
#   it cannot exist, and every caller then FAILS OPEN — a box that cannot write
#   its ledger keeps today's behaviour rather than losing pre-planning entirely.
_preplan_state() {
  local h="${1:-}"
  [ -n "$h" ] || return 1
  mkdir -p "$h/state/preplan" 2>/dev/null || return 1
  printf '%s/state/preplan\n' "$h"
}

# preplan_replan_fp <harness> <key> -> a short fingerprint of the TICKET as the
#   ready queue states it, ISO timestamps stripped. Never empty: a key with no
#   queue line (a child, a speculative candidate) fingerprints its own name, so
#   the marker is still comparable and still terminal.
preplan_replan_fp() {
  local h="${1:-$(_preplan_root)}" k="${2:-}" line=""
  [ -n "$h" ] && line=$(grep -E "^$k " "$h/logs/READY-QUEUE.log" 2>/dev/null \
         | sed -E 's/20[0-9]{2}-[0-9]{2}-[0-9]{2}[T ][0-9:.]{5,12}Z?//g')
  [ -n "$line" ] || line="no-queue-line/$k"
  printf '%s' "$line" | { sha256sum 2>/dev/null || cksum; } | tr -dc '0-9a-f' | cut -c1-16
}

# preplan_deferred <harness> <project> <key> <fp>
#   rc 0 -> TERMINAL for this fingerprint: launch nothing and say nothing (the
#           one PREPLAN_SKIP line was written when the marker was created).
#   rc 1 -> not terminal. A marker for a DIFFERENT fingerprint, or one older
#           than the window, is removed here along with its counter — that is
#           the re-arm, and it is why this is asked before anything else.
preplan_deferred() {
  local h="${1:-}" p="${2:-}" k="${3:-}" fp="${4:-}" d f mfp mts now win=86400
  d=$(_preplan_state "$h") || return 1
  f="$d/$p-$k.defer"
  [ -s "$f" ] || return 1
  mfp=$(awk 'NR==1{print $2}' "$f" 2>/dev/null)
  mts=$(awk 'NR==1{print $3}' "$f" 2>/dev/null)
  case "$mts" in ''|*[!0-9]*) mts=0 ;; esac
  now=$(date +%s 2>/dev/null); case "$now" in ''|*[!0-9]*) now=0 ;; esac
  # An unreadable clock clears the marker and allows the re-plan; a stale
  # marker must never outlive a broken clock.
  if [ "$now" -eq 0 ]; then
    rm -f "$f" "$d/$p-$k.replans" 2>/dev/null
    return 1
  fi
  if [ "$mfp" != "$fp" ] || [ $((now - mts)) -ge "$win" ]; then
    rm -f "$f" "$d/$p-$k.replans" 2>/dev/null
    return 1
  fi
  return 0
}

# preplan_replan_allow <harness> <project> <key> <fp>
#   rc 0 -> ALLOW. The attempt is persisted BEFORE this returns, so the count is
#           true even if the session that follows dies, is killed mid-plan, or
#           the box reboots. A counter that is written after the launch is a
#           counter that never reaches the cap.
#   rc 1 -> DENY, and the terminal marker is written here. The caller logs its
#           single PREPLAN_SKIP line on this branch and on no other, which is
#           what makes the line once-per-key rather than once-per-tick.
#
#   Stamps outside the window are pruned rather than counted, and anything that
#   is not a stamp is dropped: a truncated or corrupt ledger FAILS OPEN (one
#   re-plan, and a repaired file), never closed. The cost of failing open is one
#   plan; the cost of failing closed is a lane that silently stops pre-planning.
preplan_replan_allow() {
  local h="${1:-}" p="${2:-}" k="${3:-}" fp="${4:-}" d f max now cut kept n win=86400
  max=$(preplan_stale_max "$h")
  d=$(_preplan_state "$h") || return 0
  f="$d/$p-$k.replans"
  now=$(date +%s 2>/dev/null); case "$now" in ''|*[!0-9]*) return 0 ;; esac
  cut=$((now - win))
  kept=$(awk -v c="$cut" '/^[0-9]+$/ && $1 >= c {print $1}' "$f" 2>/dev/null)
  n=$(printf '%s' "$kept" | grep -c .)
  if [ "$n" -ge "$max" ]; then
    printf 'PREPLAN_DEFER_TO_BUILD %s %s\n' "$fp" "$now" > "$d/$p-$k.defer" 2>/dev/null
    return 1
  fi
  { [ -n "$kept" ] && printf '%s\n' "$kept"; printf '%s\n' "$now"; } > "$f" 2>/dev/null
  return 0
}

# --- skip a pre-plan that adds nothing (P2, 2026-09-25) ----------------------
# WHY (cost rows, 7 days to 2026-09-25): preplan $4.4K ran IN ADDITION to plan
# $6.5K. A pre-plan buys latency, never correctness: the build's PLAN stage
# plans from scratch whenever no fresh pre-plan is there (preplan adopt in
# bin/lib/rb/plan.sh). So a pre-plan is waste whenever the latency it buys is
# nothing, and three cases are decidable without a model:
#   size    triage sized the ticket S/XS (`size=S` on its READY-QUEUE line).
#           A small plan is a few minutes of the build's own PLAN stage, and the
#           pre-plan of it is the same session bought twice whenever the build
#           starts before the pre-plan lands (PREPLAN_MISS, then a fresh plan).
#   kind    copy/docs work: `kind=copy|docs` on the queue line, or the board's
#           own title prefix read through bin/kind-gate.sh — the SAME vocabulary
#           the build's kind flow uses, so "is this copy" has one answer. The
#           plan prompt already says a copy ticket deserves a dozen-line plan.
#   build   the key is being BUILT right now (preplan_midbuild_keys), so its PLAN
#           stage is planning it; a pre-plan launched now can only lose the race.
# Every case fails OPEN (pre-plans exactly as before): no queue line, no
# fingerprint, no kind-gate, an unknown kind. The build stage still plans every
# skipped key, so a wrong skip costs latency, never a wrong PR.
#
# THE KNOB: PREPLAN_SKIP_SMALL (a settings row on the preplan-tick lane,
# `lane.preplan-tick.preplan_skip_small`, exported by the tick's lane_env_apply;
# env/global.env; default 1). 0 restores the previous behaviour byte for byte;
# flags/preplan-skip-small-off (or the `switch.preplan-skip-small-off` settings
# row) is the 3am switch, the same shape as
# preplan-speculative-off.

# preplan_skip_small_on [harness] -> 1 | 0     (DEFAULT 1)
preplan_skip_small_on() {
  local h="${1:-$(_preplan_root)}" v
  [ -n "$h" ] && HARNESS="$h" lane_switch preplan-skip-small-off file && { printf '0\n'; return 0; }
  v=$(_preplan_env "$h" PREPLAN_SKIP_SMALL 1)
  case "$v" in 0|no|off|false) printf '0\n' ;; *) printf '1\n' ;; esac
}

# _preplan_queue_line <harness> <key> -> the key's READY-QUEUE.log line, or nothing
_preplan_queue_line() {
  grep -E "^${2:-} " "${1:-}/logs/READY-QUEUE.log" 2>/dev/null | tail -1
}

# _preplan_board_title <harness> <project> <key> -> the title the gate's own
#   fingerprint holds for this key, or nothing. In-app boards resolve the key
#   through state/<p>.keymap.json (the map bin/triage-gate.sh rebuilds every
#   consumed tick); a GitHub-Issues board keys <PREFIX>-<issue number>. Reads
#   files only — no board call.
_preplan_board_title() {
  local h="${1:-}" p="${2:-}" k="${3:-}" g id n
  g="$h/state/$p.gate.json"
  [ -s "$g" ] && command -v jq >/dev/null 2>&1 || return 0
  if jq -e 'type=="object" and has("issues")' "$g" >/dev/null 2>&1; then
    n="${k##*-}"
    case "$n" in ''|*[!0-9]*) return 0 ;; esac
    jq -r --argjson n "$n" '[.issues[]? | select(.number == $n) | .title // ""][0] // ""' "$g" 2>/dev/null
    return 0
  fi
  id=$(jq -r --arg k "$k" '.[$k] // empty' "$h/state/$p.keymap.json" 2>/dev/null)
  [ -n "$id" ] || return 0
  jq -r --arg id "$id" '[to_entries[] | select(.key != "meta") | .value[]? | select((.id|tostring) == $id) | .title // ""][0] // ""' "$g" 2>/dev/null
}

# _preplan_title_kind <harness> <title> -> the KIND bin/kind-gate.sh's hint
#   gives that title, or nothing. kind-gate reads only <dir>/ticket-meta.json,
#   so a scratch dir holding the title IS the question; rc 3 (no plan.md) is
#   its documented pre-PLAN answer and the hint line is printed before it.
_preplan_title_kind() {
  local h="${1:-}" t="${2:-}" kg="" c d k
  [ -n "$t" ] || return 0
  for c in "$h/bin/kind-gate.sh" "$(dirname "${BASH_SOURCE[0]}")/../kind-gate.sh"; do
    [ -r "$c" ] && { kg="$c"; break; }
  done
  [ -n "$kg" ] && command -v jq >/dev/null 2>&1 || return 0
  d=$(mktemp -d 2>/dev/null) || return 0
  jq -nc --arg t "$t" '{title:$t}' > "$d/ticket-meta.json" 2>/dev/null
  k=$(bash "$kg" "$d" 2>/dev/null | sed -n 's/^KIND_HINT:[[:space:]]*//p' | tail -1)
  rm -rf "$d"
  [ "$k" = none ] || printf '%s\n' "$k"
}

# preplan_small_reason <harness> <project> <key> [midbuild-keys]
#   rc 0 + one line of reason -> do NOT pre-plan this key; the build plans it.
#   rc 1 and nothing          -> pre-plan as before.
#   [midbuild-keys] is preplan_midbuild_keys' output, handed in by a caller
#   that already paid for it (bin/preplan-tick.sh asks once per project); with
#   no list the build case is simply not asked.
preplan_small_reason() {
  local h="${1:-}" p="${2:-}" k="${3:-}" mid="${4:-}" line tok v t kind
  [ -n "$h" ] && [ -n "$p" ] && [ -n "$k" ] || return 1
  [ "$(preplan_skip_small_on "$h")" = 1 ] || return 1
  if [ -n "$mid" ] && grep -qxF -- "$k" <<<"$mid"; then
    printf 'build-running: %s is being built now, and its PLAN stage plans it\n' "$k"; return 0
  fi
  line=$(_preplan_queue_line "$h" "$k")
  if [ -n "$line" ]; then
    # `size=S`, `size:S`, `SIZE: XS` as its own word — never `resize=S`.
    tok=$(printf '%s\n' "$line" | grep -oiE '(^|[[:space:]]|\[|\()size[[:space:]]*[=:][[:space:]]*[A-Za-z]+' | head -1)
    v=$(printf '%s' "$tok" | sed -E 's/.*[=:][[:space:]]*//' | tr '[:lower:]' '[:upper:]')
    case "$v" in S|XS) printf 'size=%s (triage), a small plan is the build'"'"'s own PLAN stage\n' "$v"; return 0 ;; esac
    # The tag vocabulary is EXACTLY the one the triage contract prints
    # (catalog/agent-contracts/triage-system-append.txt, QUEUE LINE TAGS):
    # bug|feature|copy|migration|infra, the KIND set bin/kind-gate.sh settles
    # on. Docs work is KIND copy there, so `copy` is the one skip value and no
    # second spelling (docs, doc) is quietly honoured (#2294 review S6).
    tok=$(printf '%s\n' "$line" | grep -oiE '(^|[[:space:]]|\[|\()kind[[:space:]]*[=:][[:space:]]*[A-Za-z]+' | head -1)
    v=$(printf '%s' "$tok" | sed -E 's/.*[=:][[:space:]]*//' | tr '[:upper:]' '[:lower:]')
    case "$v" in copy) printf 'kind=copy (triage), copy/docs work gets its plan in-build\n'; return 0 ;; esac
  fi
  t=$(_preplan_board_title "$h" "$p" "$k")
  kind=$(_preplan_title_kind "$h" "$t")
  if [ "$kind" = copy ]; then
    printf 'kind=copy (board title "%s"), copy/docs work gets its plan in-build\n' "$(printf '%s' "$t" | cut -c1-60)"; return 0
  fi
  return 1
}

# preplan_small_log <harness> <project> <key> <reason> <log>
#   One PREPLAN_SKIP small line per key per reason: the tick runs every two
#   minutes and a line per tick would bury the log. The marker lives in the
#   pre-plan STATE dir, not in plans/.
#
#   THE FILE LIST SURVIVES THE SKIP (#2294 review I1). The pre-plan was also
#   where plans/<p>-<KEY>/planned-files.txt came from, and four readers need it:
#   bin/dep-verify.sh (missing = UNKNOWN = obeyed as HARD, so a skipped child
#   would serialise behind its blocker), bin/overlap-guard.sh (launches blind),
#   bin/overlap-schedule.sh and the train. So on the first skip of a key this
#   runs bin/planned-files-cheap.sh on its FREE tiers only (ticket-body paths,
#   codegraph importers; PLANNED_FILES_FREE_ONLY=1 stops before the tier-3
#   model call), once per key per reason, alongside the log line. It writes
#   planned-files.txt and never plan.md, so nothing here is adoptable as a plan
#   (preplan_find requires plan.md) and an existing plan.md is left alone by
#   the script itself. In-app boards have no issue body for it to read, so for
#   those it writes nothing, exactly as bin/preplan-candidates.sh sees today.
preplan_small_log() {
  local h="${1:-}" p="${2:-}" k="${3:-}" r="${4:-}" log="${5:-}" d m="" pfc
  d=$(_preplan_state "$h") || d=""
  [ -n "$d" ] && m="$d/$p-$k.small"
  if [ -n "$m" ] && [ "$(cat "$m" 2>/dev/null)" = "$r" ]; then return 0; fi
  [ -n "$m" ] && printf '%s\n' "$r" > "$m" 2>/dev/null
  mkdir -p "$(dirname "$log")" 2>/dev/null
  echo "$(date -u '+%F %TZ') [$p/$k] PREPLAN_SKIP small: $r — the build stage plans it" >> "$log"
  pfc="$h/bin/planned-files-cheap.sh"
  if [ -x "$pfc" ] && [ ! -s "$h/plans/$p-$k/planned-files.txt" ]; then
    HARNESS="$h" PLANNED_FILES_FREE_ONLY=1 "$pfc" "$p" "$k" >/dev/null 2>&1 || true
  fi
  return 0
}
