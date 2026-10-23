#!/bin/bash
# bin/lib/rebase-job.sh — the MACHINE side of a pool rebase (BH-486).
# Sourced, never executed: no `set -e`, no `exit`, no output and no file written
# at source time — a sourced `exit` would kill the lane that sourced it.
#
# WHAT THIS FILE IS. Under REBASE_ON_POOL (see mc_pool_rebase_enabled in
# bin/lib/merge-conductor-lib.sh) the hub stops cloning, merging and gating on
# its own disk: it writes a queue row and a pool machine does the work. This is
# the contract between those two halves — the job the machine receives and the
# RESULT it writes back — and, since BH-543, the body that does the work.
# fly/builder-runner.sh's run_rebase_job is its one production caller.
#
# THE JOB the runner reads (fly/builder-runner.sh already reads ticket_id, key
# and attempt today; `rebase` is the new member, carried from the queue row's
# meta by bin/fly-dispatch.sh in BH-486.3):
#
#   {
#     "ticket_id": "...",
#     "key": "RB-<num>-<head8>",          # mc_pool_rebase_key
#     "attempt": 1,
#     ...
#     "rebase": {
#       "kind": "rebase",
#       "slug": "owner/repo",
#       "url": "https://github.com/owner/repo/pull/<num>",
#       "pr": <num>,
#       "branch": "ticket/x-1",
#       "head": "<sha the hub read this tick>",
#       "base": "main"
#     }
#   }
#
# THE RESULT the hub reads back. First line is one of these five words, and
# nothing else is a RESULT (bin/result-prefix-ok.sh is the gate):
#
#   REBASED <new-sha>
#   CONFLICT <path> [<path>...]
#   GATE_RED typecheck|unit|migration-number: <message>
#            typecheck and unit carry `: <first failing line>` when the gate's
#            output has a tsc error or a vitest/jest FAIL line (_rj_first_fail,
#            BH-7656), plus ` [postinstall rc=<n>]` when step 6d failed; with no
#            such line the word stands alone.
#   REBASE_LEASE_REJECTED <why>
#   REBASE_SETUP_FAILED <why>
#   REBASE_SKIPPED mergify-queue: <why> | migration-apply-lane: <why>   (BH-8035)
#            another lane holds the PR, so nothing was pushed; the hub's
#            mc_pool_rebase_apply reads it as a clean no-op.
#
# then, one per line, in this order:
#
#   PR: <url>
#   HEAD: <old-head>
#   BRANCH: <branch>
#   BASE: <base>
#   GATE: typecheck=<rc|skipped> unit=<rc|skipped|select>
#   UNION: <path> (BH-4641)[;<path> ...]   only when the append-union step
#          resolved part of this merge (the merge commit's `Union-resolved:`
#          trailers). mc_pool_rebase_apply then withholds the approval rebind.
#   TIMINGS: setup=<s> merge=<s> gates=<s> push=<s>   always, last. Seconds per
#          step: setup is steps 1-5 (from REBASE_JOB_T0 when the runner sets it,
#          so the warm-up counts; else from the start of rebase_job_run), merge
#          6-6c, gates 7, push 8. The step that decided the RESULT carries its
#          time up to that point; a step never reached is `-`. The hub reap logs
#          it; mc_pool_rebase_apply does not read it.
#
# TWO KNOBS, both optional, both with a documented fallback:
#
#   REBASE_JOB_URL   the PR url for the `PR:` line. The signature carries no
#                    url, so fly/builder-runner.sh exports it from the job's
#                    `.rebase.url`. Unset -> the slug-derived form with `-` for
#                    the number. A number is NEVER invented.
#   REBASE_WT_DIR    where the per-job worktree is made. Unset -> /data/worktrees
#                    when it exists (the pool machine's volume), else $TMPDIR.
#   REBASE_JOB_MERGIFY  `true` when the hub queued the row for a Mergify repo
#                    (the row meta's `mergify`, BH-8035). Step 8 then reads the
#                    Mergify hold again just before the push. Unset -> no read.
#   REBASE_JOB_HOLD  the row meta's `hold` (BH-8035): the migration hold gave
#                    the PR to an apply lane when the hub queued the row. Set ->
#                    REBASE_SKIPPED at step 2, before any git. Unset -> nothing.
#
# WHAT THE BODY DOES, in order, each step with its own RESULT word:
#
#   1. resolver first. mc_resolve_conflicts comes from the HARNESS copy of
#      bin/lib/merge-conductor-lib.sh, sourced only if it is not already a
#      function. Unreadable -> REBASE_SETUP_FAILED no conflict resolver, and
#      NOT a plain merge: a rebase that cannot resolve is a rebase that must
#      not start.
#   2. job sanity, before any git. Empty branch/head/base is refused; so is a
#      branch named main, master, or the base itself — this box never
#      force-pushes a protected branch, whatever the job says.
#   3. fetch with EXPLICIT destination refspecs, +refs/heads/<ref>:refs/remotes/
#      origin/<ref> for both base and branch, and --unshallow when (and only
#      when) the repo is shallow. fly/Dockerfile clones --depth 50, which
#      implies --single-branch: a bare `fetch origin <branch>` would land in
#      FETCH_HEAD only, and a branch that forked before the depth boundary has
#      no merge base until the repo is deepened ("unrelated histories").
#      --unshallow on an already-complete repo is fatal, hence the guard.
#   4. a per-job worktree from mktemp -d, checked out detached at origin/<branch>.
#   5. the LEASE: HEAD must still be <head>, before any merge.
#   6. merge origin/<base>; conflicts go to mc_resolve_conflicts; a leftover
#      conflict is CONFLICT <paths> and the merge is aborted. A merge that
#      failed with NO unmerged paths is a git fatal, not a conflict, and is
#      REBASE_SETUP_FAILED merge failed (BH-517's empty-conflict trap).
#   6b. regenerate, when the repo declares generated files (BH-969). The base's
#      own `## Generated files` table is run over the MERGED tree and the
#      declared paths land as ONE extra commit when the output differs; a
#      failing generator is logged and changes nothing. Guarded by `type`, so a
#      machine carrying a pre-BH-969 conductor lib skips it silently.
#   6c. renumber a branch-added migration whose number main took (BH-7365,
#      bin/lib/migration-renumber.sh): one commit whose trailers join UNION:.
#      A collision it cannot renumber is GATE_RED migration-number: <message>.
#   6d. the generate step, inside the same node_modules condition as 7 (BH-7656):
#      when the MERGED tree's package.json declares a root `postinstall`, run
#      `npm run postinstall` in the worktree. That is the step `npm install`
#      runs for a build, and a fresh `git worktree add` never runs it. The
#      project-6 false red: `postinstall` is `prisma generate`, the client is
#      written to the git-ignored `src/lib/db/__generated__/prisma`, so the
#      worktree had no client and tsc was red on every import of it. A failing
#      postinstall does not stop the job: typecheck decides, and a red typecheck
#      names it. `pretypecheck` (project-6's registry step) npm runs by itself.
#   7. gates, ONLY when <repo>/node_modules exists — warm-up installs with
#      `npm install || true`, so calling a missing install GATE_RED would tell
#      the hub the BRANCH is bad. Same condition as the hub twin mc_rebase.
#      The root node_modules is linked, then each workspace's nested one
#      (_rj_link_ws, BH-7953).
#      typecheck, then <harness>/bin/test-select.sh if it is executable
#      (recorded as unit=select) else `npm run test:unit`. Red pushes nothing.
#      Gate output goes to one temp log (removed on every path), and a red gate
#      names its first failing line from it.
#   8. push --force-with-lease=<branch>:<head>; refused -> REBASE_LEASE_REJECTED
#      push, origin untouched. The RESULT is written AFTER the push returns,
#      from the sha read after it, so a REBASED line without a push cannot
#      happen. No approval rebind here — the ledger is the hub's.
#
# The worktree is aborted, removed and pruned on EVERY path, and the RESULT is
# ONE printf so a reader never sees a first line without its trailer.
#
# rebase_job_run <repo> <slug> <branch> <head> <base> <result-file> [<harness>]
#   Does the rebase in <repo> and writes <result-file>. rc 0 only on REBASED.
rebase_job_run() {
  local repo="$1" slug="$2" br="$3" head="$4" base="$5" out="$6"
  local harness="${7:-${HARNESS:-/data/harness}}"
  # `local -` restores the caller's shell options on return: this is sourced
  # into a long-running runner, and a leaked `set -u` would kill it later.
  local -
  set -uo pipefail
  # The four dynamically scoped slots _rebase_job_body reports through. They are
  # locals HERE so an early `return` from any step still lands in the cleanup
  # and the single write below.
  local _rj_line="REBASE_SETUP_FAILED unknown" _rj_wt="" _rj_tc=skipped _rj_unit=skipped _rj_union=""
  # The step clock (_rj_mark): the step in progress and the time it started.
  local _rj_ts=- _rj_tm=- _rj_tg=- _rj_tp=- _rj_step=_rj_ts _rj_t0="${REBASE_JOB_T0:-}"
  case "$_rj_t0" in ''|*[!0-9]*) _rj_t0=$(date -u +%s) ;; esac
  # The gate log (BH-7656): typecheck and unit output, read by _rj_first_fail.
  # The postinstall output goes beside it in "$_rj_log.pi".
  local _rj_log _rj_pilog=/dev/null _rj_pi=""
  if _rj_log=$(mktemp "${TMPDIR:-/tmp}/rebase-log-XXXXXX" 2>/dev/null); then _rj_pilog="$_rj_log.pi"
  else _rj_log=/dev/null; fi
  _rebase_job_body "$repo" "$slug" "$br" "$head" "$base" "$harness"
  # The step that decided (a return from the body) carries its time so far.
  _rj_mark ""
  [ "$_rj_log" = /dev/null ] || rm -f "$_rj_log" "$_rj_pilog" >/dev/null 2>&1
  if [ -n "$_rj_wt" ]; then
    git -C "$_rj_wt" merge --abort >/dev/null 2>&1
    git -C "$repo" worktree remove --force "$_rj_wt" >/dev/null 2>&1
    rm -rf "$_rj_wt" >/dev/null 2>&1
    git -C "$repo" worktree prune >/dev/null 2>&1
  fi
  local url="${REBASE_JOB_URL:-}"
  [ -n "$url" ] || url="https://github.com/$slug/pull/-"
  local ul=""; [ -z "$_rj_union" ] || ul="UNION: $_rj_union"$'\n'
  printf '%s\nPR: %s\nHEAD: %s\nBRANCH: %s\nBASE: %s\nGATE: typecheck=%s unit=%s\n%sTIMINGS: setup=%s merge=%s gates=%s push=%s\n' \
    "$_rj_line" "$url" "$head" "$br" "$base" "$_rj_tc" "$_rj_unit" "$ul" \
    "$_rj_ts" "$_rj_tm" "$_rj_tg" "$_rj_tp" > "$out" 2>/dev/null
  case "$_rj_line" in REBASED\ *) return 0 ;; *) return 1 ;; esac
}

# _rj_mark <next-step-var> — rebase_job_run's step clock: the step in progress
#   (_rj_step) gets the seconds since _rj_t0, and <next-step-var> starts now.
#   "" ends the clock. Reports through rebase_job_run's locals.
_rj_mark() {
  local now; now=$(date -u +%s)
  [ -z "$_rj_step" ] || printf -v "$_rj_step" '%s' "$((now - _rj_t0))"
  _rj_step="$1"; _rj_t0="$now"
}

# _rj_first_fail <log> — the first failing line of a gate log, or nothing.
#   A tsc error (`<path>(<l>,<c>): error TS…` or the pretty `<path>:<l>:<c> -
#   error TS…`) or a vitest/jest failure (`FAIL <path>`, `× <path>`). ANSI codes
#   are stripped, tabs and CR become spaces, the ends are trimmed, and the line
#   is cut at 200 bytes. A warning, an `npm ERR!` line or a script echo line is
#   no match: the caller then keeps the bare GATE_RED word.
_rj_first_fail() {
  [ -s "${1:-}" ] || return 0
  sed 's/\x1b\[[0-9;]*[A-Za-z]//g' "$1" 2>/dev/null \
    | LC_ALL=C grep -m1 -E \
        -e '^.+\([0-9]+,[0-9]+\): error TS[0-9]+' \
        -e '^.+:[0-9]+:[0-9]+ - error TS[0-9]+' \
        -e '^[[:space:]]*FAIL[[:space:]]+[^[:space:]]' \
        -e '^[[:space:]]*× [^[:space:]]' \
    | tr '\t\r' '  ' | sed 's/^ *//; s/ *$//' | LC_ALL=C cut -b1-200
}

# _rj_red <gate> — the GATE_RED line for a red <gate>: the first failing line of
#   the gate log, then the postinstall rc when step 6d failed.
_rj_red() {
  local f; f=$(_rj_first_fail "$_rj_log")
  _rj_line="GATE_RED $1${f:+: $f}"
  case "$_rj_pi" in ''|0) ;; *) _rj_line="$_rj_line [postinstall rc=$_rj_pi]" ;; esac
}

# _rj_link_ws <repo> <wt> — link each npm workspace's nested node_modules
#   (BH-7953). npm puts a dep whose version conflicts with the root in
#   <ws>/node_modules, and a fresh worktree has none, so project-6's
#   `npm run typecheck --workspaces` was TS2307 on ajv in packages/spec-compiler.
#   The workspaces are read from the MERGED tree's package.json, the array form
#   or {packages:[...]}. A glob expands against <repo>, the install; an entry
#   with `..`, `**`, `!` or a leading `/` is skipped. A dir is linked only when
#   <repo>/<dir>/node_modules exists, <wt>/<dir> exists and
#   <wt>/<dir>/node_modules does not. No workspaces -> nothing, as before.
_rj_link_ws() {
  local repo="$1" wt="$2" g d
  jq -r '((.workspaces | if type == "object" then .packages else . end) // [])
         | if type == "array" then .[] else empty end | strings' \
    "$wt/package.json" 2>/dev/null | while IFS= read -r g; do
    case "$g" in ''|/*|*..*|*'**'*|'!'*) continue ;; esac
    # shellcheck disable=SC2086  # the glob must expand
    for d in "$repo"/${g%/}; do
      d="${d#"$repo"/}"
      [ -d "$repo/$d/node_modules" ] && [ -d "$wt/$d" ] && [ ! -e "$wt/$d/node_modules" ] \
        && ln -s "$repo/$d/node_modules" "$wt/$d/node_modules" 2>/dev/null
    done
  done
  return 0
}

# _rebase_job_body <repo> <slug> <branch> <head> <base> <harness>
#   The steps. Reports through _rj_line / _rj_wt / _rj_tc / _rj_unit, which are
#   rebase_job_run's locals — every `return` here is a step that decided, and
#   the caller owns the cleanup and the write.
_rebase_job_body() {
  # $2 is the slug, and it is deliberately not bound here: it decides the PR:
  # fallback, which rebase_job_run owns, and the step 8 Mergify read (BH-8035).
  local repo="$1" br="$3" head="$4" base="$5" harness="$6"
  local wt wtbase shallow conf new actual rc lib="$harness/bin/lib/merge-conductor-lib.sh"
  local fargs=()

  # --- 1. the resolver, or nothing ------------------------------------------
  # The READABILITY check is unconditional — a machine whose harness carries no
  # conductor lib has no conflict policy, and the answer to that is to stop, not
  # to merge with whatever happens to be in the current shell. Only the SOURCE
  # is skipped when the function is already here.
  [ -r "$lib" ] || { _rj_line="REBASE_SETUP_FAILED no conflict resolver"; return 1; }
  if ! type mc_resolve_conflicts >/dev/null 2>&1; then
    # mc_resolve_generated calls mc_log, so MC_LOG's directory must exist; the
    # local HARNESS points MC_H/MC_LOG at THIS machine's harness for the source
    # and unwinds with the function. mc_init is deliberately never called — it
    # would create the hub's state tree on a machine that owns no ledger.
    mkdir -p "$harness/logs" >/dev/null 2>&1
    local HARNESS="$harness"
    # `set +u` across the source only: an unbound variable under `set -u` exits
    # the shell outright, and that shell is the runner.
    set +u
    # shellcheck source=bin/lib/merge-conductor-lib.sh
    . "$lib" >/dev/null 2>&1
    set -u
    type mc_resolve_conflicts >/dev/null 2>&1 \
      || { _rj_line="REBASE_SETUP_FAILED no conflict resolver"; return 1; }
  fi

  # --- 2. job sanity, before any git ----------------------------------------
  [ -n "$br" ] && [ -n "$head" ] && [ -n "$base" ] \
    || { _rj_line="REBASE_SETUP_FAILED job is missing branch, head or base"; return 1; }
  # NEVER a protected branch. The push below is --force-with-lease, and the one
  # thing this box may not do is move main — whatever `base` claims.
  case "$br" in
    main|master|"$base") _rj_line="REBASE_SETUP_FAILED branch is protected"; return 1 ;;
  esac
  # 2b. THE APPLY LANE OWNS IT (BH-8035): the hub saw it when it queued the row,
  # and a push resets that lane's run (project-6 #2362). No git at all.
  if [ -n "${REBASE_JOB_HOLD:-}" ]; then
    _rj_line="REBASE_SKIPPED $(printf '%s' "$REBASE_JOB_HOLD" | tr '\t\r\n' '   ')"; return 1
  fi

  # --- 3. fetch both sides, by explicit refspec ------------------------------
  shallow=$(git -C "$repo" rev-parse --is-shallow-repository 2>/dev/null)
  [ "$shallow" = true ] && fargs+=(--unshallow)
  git -C "$repo" fetch -q ${fargs[@]+"${fargs[@]}"} origin \
      "+refs/heads/$base:refs/remotes/origin/$base" \
      "+refs/heads/$br:refs/remotes/origin/$br" >/dev/null 2>&1 \
    || { _rj_line="REBASE_SETUP_FAILED fetch failed"; return 1; }

  # --- 4. the per-job worktree ----------------------------------------------
  if [ -n "${REBASE_WT_DIR:-}" ]; then wtbase="$REBASE_WT_DIR"
  elif [ -d /data/worktrees ];  then wtbase=/data/worktrees
  else wtbase="${TMPDIR:-/tmp}"; fi
  mkdir -p "$wtbase" >/dev/null 2>&1
  wt=$(mktemp -d "$wtbase/rebase-XXXXXX" 2>/dev/null) \
    || { _rj_line="REBASE_SETUP_FAILED worktree add failed"; return 1; }
  _rj_wt="$wt"
  git -C "$repo" worktree add -f --detach "$wt" "origin/$br" >/dev/null 2>&1 \
    || { _rj_line="REBASE_SETUP_FAILED worktree add failed"; return 1; }

  # --- 5. the lease, before the merge ---------------------------------------
  actual=$(git -C "$wt" rev-parse HEAD 2>/dev/null)
  [ "$actual" = "$head" ] \
    || { _rj_line="REBASE_LEASE_REJECTED head is $actual"; return 1; }
  _rj_mark _rj_tm

  # --- 6. merge, resolve, commit --------------------------------------------
  if ! git -C "$wt" merge -q --no-edit "origin/$base" >/dev/null 2>&1; then
    if [ -z "$(git -C "$wt" diff --name-only --diff-filter=U)" ]; then
      # git refused the merge outright and left nothing to resolve. The resolver
      # answers rc 0 on an empty conflict list, so reading this as "resolved"
      # would commit a merge that never happened.
      _rj_line="REBASE_SETUP_FAILED merge failed"; return 1
    fi
    if ! conf=$(mc_resolve_conflicts "$wt" "$br"); then
      _rj_line="CONFLICT $(printf '%s' "$conf" | tr '\n' ' ' | sed 's/  */ /g; s/ *$//')"
      return 1
    fi
    git -C "$wt" -c commit.gpgsign=false commit -q --no-edit >/dev/null 2>&1 \
      || { _rj_line="REBASE_SETUP_FAILED commit failed"; return 1; }
    # BH-4641: what the append-union step resolved, from this merge commit only.
    _rj_union=$(git -C "$wt" log -1 --format=%B HEAD 2>/dev/null | sed -n 's/^Union-resolved: //p' | tr '\n' ';' | sed 's/;$//')
  fi

  # --- 6b. regenerate the declared generated files ---------------------------
  # BH-969, the pool twin of mc_rebase's own call: the merged tree is what the
  # repo's generator is a pure function of, and a stale generated file pushed
  # from here fails CI's drift step on the PR. node_modules is linked FIRST (a
  # generator may need the deps), and the call is `type`-guarded so a pool
  # machine whose harness copy of the conductor lib predates BH-969 rebases
  # exactly as it did before instead of dying on a missing function.
  if [ -d "$repo/node_modules" ]; then
    [ -e "$wt/node_modules" ] || ln -s "$repo/node_modules" "$wt/node_modules" 2>/dev/null
  fi
  if type mc_regen_generated >/dev/null 2>&1; then
    mc_regen_generated "$wt" "origin/$base" "pool rebase $br" || true
  fi

  # --- 6c. renumber a migration number main already took (BH-7365) ----------
  # The pool twin of mc_rebase's call, `type`-guarded the same way. A decline is
  # GATE_RED (nothing pushed); could-not-run goes on and CI decides. The
  # commit's `Union-resolved:` trailers join UNION:, so the hub withholds the
  # approval rebind exactly as for a union-resolved merge.
  if [ "$base" = main ] && type mnr_fix >/dev/null 2>&1; then
    local mnr mnrc=0 mnu mnp="${REBASE_JOB_URL:-}"
    mnr=$(mnr_fix "$wt" "origin/$base" "${PROJECT:-}" "$br" "${mnp##*/}" 2>/dev/null) || mnrc=$?
    if [ "$mnrc" = 1 ]; then
      _rj_line="GATE_RED migration-number: $(printf '%s' "$mnr" | tr '\n' ' ' | sed 's/  */ /g; s/ *$//')"
      return 1
    fi
    if [ "$mnrc" = 0 ] && [ -n "$mnr" ]; then
      mnu=$(git -C "$wt" log -1 --format=%B HEAD 2>/dev/null | sed -n 's/^Union-resolved: //p' | tr '\n' ';' | sed 's/;$//')
      [ -n "$mnu" ] && _rj_union="${_rj_union:+$_rj_union;}$mnu"
    fi
  fi

  _rj_mark _rj_tg

  # --- 7. the gates, only with deps at hand ----------------------------------
  if [ -d "$repo/node_modules" ]; then
    [ -e "$wt/node_modules" ] || ln -s "$repo/node_modules" "$wt/node_modules" 2>/dev/null
    # BH-7953: and each workspace's own node_modules, which npm nests on a
    # version conflict (project-6's packages/spec-compiler/node_modules/ajv).
    _rj_link_ws "$repo" "$wt"
    # --- 6d. the generate step (BH-7656) -----------------------------------
    # Read from the MERGED tree, so a branch that adds the script runs it. With
    # Prisma < 7 the client goes to node_modules/.prisma, which is the linked
    # $repo/node_modules: one job runs at a time on a pool machine, and a build
    # re-installs, so that write is accepted.
    if jq -e '.scripts.postinstall' "$wt/package.json" >/dev/null 2>&1; then
      ( cd "$wt" && npm run postinstall >"$_rj_pilog" 2>&1 ); _rj_pi=$?
    fi
    if jq -e '.scripts.typecheck' "$wt/package.json" >/dev/null 2>&1; then
      ( cd "$wt" && NODE_OPTIONS=--max-old-space-size=12288 npm run typecheck >"$_rj_log" 2>&1 ); _rj_tc=$?
      [ "$_rj_tc" = 0 ] || { _rj_red typecheck; return 1; }
    fi
    if [ -x "$harness/bin/test-select.sh" ]; then
      "$harness/bin/test-select.sh" "$wt" "$br" "$base" >"$_rj_log" 2>&1; rc=$?
      _rj_unit=select
      [ "$rc" = 0 ] || { _rj_red unit; return 1; }
    elif jq -e '.scripts["test:unit"]' "$wt/package.json" >/dev/null 2>&1; then
      ( cd "$wt" && npm run test:unit >"$_rj_log" 2>&1 ); _rj_unit=$?
      [ "$_rj_unit" = 0 ] || { _rj_red unit; return 1; }
    fi
  fi

  _rj_mark _rj_tp

  # --- 8. the one write that leaves this machine -----------------------------
  # The ticket's hold is read HERE, at the push, not when the hub enqueued this
  # job minutes ago (BH-2504): a lead who held the ticket in between owns the
  # branch now. The runner's $PROJECT names the lane; the lease is the head the
  # hub read. A hold is not a lease failure, and says so.
  # Beside this file first (the copy this runner sourced), then the harness's.
  if ! command -v hold_push >/dev/null 2>&1; then
    # shellcheck source=bin/lib/hold-push.sh
    . "$(dirname "${BASH_SOURCE[0]}")/hold-push.sh" 2>/dev/null \
      || . "$harness/bin/lib/hold-push.sh" 2>/dev/null \
      || { _rj_line="REBASE_SETUP_FAILED no bin/lib/hold-push.sh on this machine"; return 1; }
  fi
  # MERGIFY HOLDS IT NOW (BH-8035): the hub twin is mc_rebase's push-time read
  # (BH-8021). The PR can enter the Mergify queue while this job runs, and a
  # push cancels it. One check-runs read of the old head, only on a Mergify
  # repo. A read that fails pushes as before, the same as the hub path.
  local mqwhy mqrc
  if [ "${REBASE_JOB_MERGIFY:-}" = true ] && [ "$base" = main ] && type mc_mergify_holds >/dev/null 2>&1; then
    mqwhy=$(mc_mergify_holds "$2" "${REBASE_JOB_URL:-}" "$head" 2>/dev/null); mqrc=$?
    if [ "$mqrc" = 0 ]; then
      _rj_line="REBASE_SKIPPED mergify-queue: $(printf '%s' "$mqwhy" | tr '\t\r\n' '   ') on ${head:0:8}"; return 1
    fi
  fi
  rc=0; hold_push "${PROJECT:--}" - "$wt" origin HEAD "$br" "$head" >/dev/null 2>&1 || rc=$?
  case "$rc" in
    0) ;;
    3) _rj_line="REBASE_SETUP_FAILED the ticket is on HOLD — not pushed"; return 1 ;;
    4) _rj_line="REBASE_SETUP_FAILED the ticket's hold could not be read — not pushed"; return 1 ;;
    *) _rj_line="REBASE_LEASE_REJECTED push"; return 1 ;;
  esac
  new=$(git -C "$wt" rev-parse HEAD 2>/dev/null)
  _rj_line="REBASED $new"
  return 0
}
