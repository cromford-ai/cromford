#!/bin/bash
# shellcheck shell=bash
# bin/lib/br/opt/mechanical.sh — BH-1470: the two rungs that answer a park with
# a git operation instead of a model call. br_opt_carry_rung rebinds a
# head-bound APPROVE when main moved and the patch's own +/- lines did not;
# br_opt_conflict_rung rebases a conflict whose only paths the repo declares
# generated or union-mergeable, and writes a cluster key when a real source file
# conflicts (the cross-ticket round that consumes it is #1457's R14, not this).
#
# bin/lib/br/opt/README.md is the NORMATIVE hook table — argv, what rc 0 costs,
# counting, why a module may call br_cron_unlock. Nothing here restates it.
# Sourced by the BR_OPT_MODULES loop of bin/blocked-resolver.sh, never run.

# bin/lib/mc/train.sh is NOT in bin/lib/merge-conductor-lib.sh's module loop
# (log locks classify queue rebase settle) — bin/batch-resolve.sh is its only
# other caller — so this is the one thing done at source time, and it only
# defines functions. A box that has not synced it keeps today's behaviour:
# _brm_ready declines and both rungs never offer. The `|| true` is there because
# a non-zero return here reaches the loader as "failed on source".
if ! command -v mrt_carry_ok >/dev/null 2>&1; then
  _brm_train="${H:-${HARNESS:-/root/harness}}/bin/lib/mc/train.sh"
  # shellcheck source=/dev/null
  [ -r "$_brm_train" ] && { . "$_brm_train" || true; }
  unset _brm_train
fi

# _brm_ready — rc 0 only when every helper both rungs need is defined and git
# resolves on PATH. A box missing any of them takes its ordinary rung.
_brm_ready() {
  local f
  for f in mrt_carry_ok mrt_rebase_pure mrt_carry_verdict mc_regen_table \
           mc_git_auth mc_project_base br_cap_key; do
    command -v "$f" >/dev/null 2>&1 || return 1
  done
  command -v git >/dev/null 2>&1
}

# _brm_done <rc> — the ONE exit path of both hooks: drop the credential
# mc_git_auth armed and the temp files, then answer. This lane is a */10 cron
# and one stray askpass or exclude file per tick is a real leak.
_BRM_EX=""; _BRM_RG=""
_brm_done() {
  command -v mc_git_auth_clear >/dev/null 2>&1 && mc_git_auth_clear
  [ -n "$_BRM_EX" ] && rm -f "$_BRM_EX"
  [ -n "$_BRM_RG" ] && rm -f "$_BRM_RG"
  _BRM_EX=""; _BRM_RG=""
  return "${1:-1}"
}

# _brm_sha <value> — rc 0 for 40 hex and nothing else. A read that did not
# answer, a `null`, a branch NAME that slid into a positional read: none may
# reach a --force-with-lease or an approval rebind.
_brm_sha() {
  case "${1:-}" in
    *[!0-9a-fA-F]*|'') return 1 ;;
    *) [ "${#1}" = 40 ] ;;
  esac
}

# _brm_exclfile <repo> <base-ref> — the paths a carry IGNORES, in a temp file
# whose path is printed. Declared generated files are a function of the tree and
# are rebuilt on both sides, so they are not part of the patch's identity
# (bin/batch-resolve.sh builds EXCL_FILE the same way).
_brm_exclfile() {
  local f
  f=$(mktemp "${TMPDIR:-/tmp}/brmech-excl-XXXXXX") || return 1
  mc_regen_table "$1" "$2" 2>/dev/null | cut -f1 | awk 'NF && !seen[$0]++' > "$f"
  printf '%s' "$f"
}

# _brm_regenfile <repo> <base-ref> — the WHOLE table, mrt_rebase_pure's 7th
# argument: excluding a generated file from the carry identity is right,
# pushing a rebase whose render no longer BUILDS is not.
_brm_regenfile() {
  local f
  f=$(mktemp "${TMPDIR:-/tmp}/brmech-regen-XXXXXX") || return 1
  mc_regen_table "$1" "$2" 2>/dev/null > "$f"
  printf '%s' "$f"
}

# _brm_repo <project> <slug> <base-branch> <head-branch> — the hub's checkout,
# ready for a merge-base read. rc 1 = decline, nothing written anywhere. Order
# mirrors br_fix_round and mc_rebase: credential, unshallow, BOUNDED fetch —
# /root/repos/<project> on the hub is a shallow clone (docs/verification-map/
# hub-repo-shallow.md) and a branch cut before its boundary has no merge base.
_brm_repo() {
  local p="$1" slug="$2" base="$3" br="$4" repo="$REPOS/$p"
  [ -d "$repo/.git" ] || return 1
  mc_git_auth "$slug" >/dev/null 2>&1 || return 1
  mc_unshallow_once "$repo" "$p" "$slug" mechanical >/dev/null 2>&1
  mc_git_bounded 180 git -C "$repo" -c credential.helper= fetch -q origin "$base" "$br" \
    >/dev/null 2>&1 || return 1
  return 0
}

# _brm_mt <repo> <base-ref> <head> — the paths a merge would conflict on, one
# per line. rc 0 clean | 1 conflict | 2 could not tell. `--name-only` puts them
# between the tree oid and the first blank line; the block after it is prose for
# humans (bin/batch-resolve.sh's mt_conflicts).
_brm_mt() {
  local out rc
  out=$(git -C "$1" merge-tree --write-tree --name-only "$2" "$3" 2>/dev/null); rc=$?
  case "$rc" in
    0) return 0 ;;
    1) printf '%s\n' "$out" | awk 'NR>1 && /^$/{exit} NR>1{print}'; return 1 ;;
    *) return 2 ;;
  esac
}

# _brm_path_ok <repo> <path> <table> — rc 0 when the REPO declares this file
# machine-written (the table's first column: exact match then as a glob, which
# is regen_cmd_for's own order) or union-mergeable. Everything else is a source
# conflict, and an EMPTY table allows NOTHING — a repo that declares no
# generated files degrades to today's path, never to "allow all".
_brm_path_ok() {
  local repo="$1" f="$2" p attr
  while IFS=$'\t' read -r p _; do
    [ -n "$p" ] || continue
    [ "$p" = "$f" ] && return 0
    # shellcheck disable=SC2254
    case "$f" in $p) return 0 ;; esac
  done <<<"$3"
  # git reads the attribute itself, so a gitattributes pattern with no slash
  # matches at any depth exactly as git means it.
  attr=$(git -C "$repo" check-attr merge -- "$f" 2>/dev/null)
  [ "${attr##*: }" = union ]
}

# br_conflict_kind <repo> <base-ref> <head>
#   -> clean | derived <paths> | source <path> | unknown
# The FIRST path that is not allowed wins and stops the scan, exactly as
# classify_pair does. ANY unread answer is `unknown` — never `clean` and never
# `derived`: this is the gate in front of a force push to somebody's branch.
br_conflict_kind() {
  local repo="${1:-}" base="${2:-}" head="${3:-}" out rc f tbl allowed=""
  [ -n "$repo" ] && [ -n "$base" ] && [ -n "$head" ] || { printf 'unknown'; return 0; }
  command -v git >/dev/null 2>&1 || { printf 'unknown'; return 0; }
  out=$(_brm_mt "$repo" "$base" "$head"); rc=$?
  [ "$rc" = 0 ] && { printf 'clean'; return 0; }
  [ "$rc" = 2 ] && { printf 'unknown'; return 0; }
  tbl=$(mc_regen_table "$repo" "$base" 2>/dev/null)
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    _brm_path_ok "$repo" "$f" "$tbl" || { printf 'source %s' "$f"; return 0; }
    allowed="${allowed:+$allowed }$f"
  done <<<"$out"
  # A conflict whose path list would not parse is an unread answer too.
  [ -n "$allowed" ] || { printf 'unknown'; return 0; }
  printf 'derived %s' "$allowed"
}

# --- the carry rung ---------------------------------------------------------
br_opt_carry_rung() { local rc; _brm_carry "$@"; rc=$?; _brm_done "$rc"; }

_brm_carry() {
  local p="$1" rkey="$2" reason="$3" url="$4" rec="$5" tkey="$6"
  local ck slug num key base old new hbr out rc
  [ "$reason" = head-not-reapproved ] || return 1
  _brm_ready || return 1
  # The LEDGER rebind is the durable half, so a box with no jobs client declines.
  type job_verdict_rebind >/dev/null 2>&1 || return 1
  case "$url" in https://github.com/*/*/pull/*) ;; *) return 1 ;; esac
  # The lane-wide scan lock is still held and a fetch takes seconds; the release
  # is idempotent, so the lane's own later call is a no-op.
  command -v br_cron_unlock >/dev/null 2>&1 && br_cron_unlock
  ck=$(br_cap_key "$p" "$rkey" "$tkey")
  slug=$(mc_slug_of_url "$url"); num=$(mc_num_of_url "$url"); key="$slug#$num"
  # THE APPROVED SHA: the build record first, then the conductor row's own
  # reviewed-sha field (br_rereview's read), because a park whose record is gone
  # still carries. Neither answering 40 hex is no carry and no counter.
  old=""
  [ -n "$rec" ] && [ "$rec" != "-" ] && [ -d "$rec" ] \
    && old=$(head -1 "$rec/reviewed-sha" 2>/dev/null)
  _brm_sha "$old" || old=$(mc_row_field "$key" 5)
  _brm_sha "$old" || return 1
  # THE LIVE HEAD, both fields in ONE read the way br_from_conductor pairs them.
  # rc 75 is "GitHub did not answer" and br_pr_field has already logged it: no
  # carry, no counter, no second line, and the next tick asks.
  out=$(br_pr_field "$url" '"\(.head.sha // "") \(.head.ref // "")"' 'head sha'); rc=$?
  [ "$rc" = 0 ] || return 1
  read -r new hbr <<<"$out"
  _brm_sha "$new" || return 1
  [ -n "$hbr" ] || return 1
  # Nothing moved: today's ladder owns it, and a replayed tick stops here.
  [ "$new" = "$old" ] && return 1
  base=$(mc_project_base "$p")
  _brm_repo "$p" "$slug" "$base" "$hbr" || return 1
  _BRM_EX=$(_brm_exclfile "$REPOS/$p" "origin/$base") || return 1
  # Conservative by construction: one different +/- line is rc 1, and an empty
  # line set on BOTH sides (a sha the clone cannot read) is not an identity.
  mrt_carry_ok "$REPOS/$p" "origin/$base" "$old" "$new" "$_BRM_EX" || return 1
  if [ "${OBSERVE:-0}" = 1 ]; then
    say "$p/$rkey [$reason]: WOULD carry the verdict from ${old:0:8} to ${new:0:8} — the patch's own +/- lines are identical — observe mode"
    return 0
  fi
  # SEND FIRST, WRITE AFTER, and the rebind's rc is READ: rc 1 is no row or an
  # outage, rc 2 a row that makes no reviewed-sha claim to move, and neither is
  # a rebind. mrt_carry_verdict swallows that rc (`|| true`), which is why this
  # asks first — a record stamped `carry` over a ledger that never moved.
  job_verdict_rebind "$url" "$new" >/dev/null 2>&1; rc=$?
  if [ "$rc" != 0 ]; then
    say "$p/$rkey [$reason]: the ledger would not rebind the verdict onto ${new:0:8} (job_verdict_rebind rc $rc) — nothing carried, nothing recorded, today's ladder runs"
    return 1
  fi
  mrt_carry_verdict "$rec" "$slug" "$p" "$num" "$url" "$new" "-" "$key"
  mc_transition "$key" WAIT_REVIEW "resolver carried the verdict onto ${new:0:8}" \
    "$new" "$new" "$url" APPROVE UNKNOWN "${rec:--}" >/dev/null
  # No counter bump: `mechanicals`/`fixrounds` are ladder rungs and this is not
  # one, so a carried PR must not walk toward the rebuild on it.
  br_record "$p" "$ck" carry "$reason" \
    "${old:0:8} -> ${new:0:8}: identical +/- line set, verdict carried"
  br_event carried "$p" "$ck" "$reason" "verdict carried from ${old:0:8} to ${new:0:8}"
  br_count carried
  say "$p/$rkey [$reason]: CARRIED the approval onto ${new:0:8} — the patch's own +/- lines are unchanged, so no re-review was bought"
  return 0
}

# --- the conflict rung ------------------------------------------------------
br_opt_conflict_rung() { local rc; _brm_conflict "$@"; rc=$?; _brm_done "$rc"; }

_brm_conflict() {
  local p="$1" rkey="$2" reason="$3" url="$4" rec="$5" tkey="$6"
  local ck slug num key base repo ref br head kind paths newhead detail ckey rc
  [ "$reason" = conflict-unresolvable ] || return 1
  [ "$(br_ladder_class "$reason")" = rebase-conflict ] || return 1
  _brm_ready || return 1
  case "$url" in https://github.com/*/*/pull/*) ;; *) return 1 ;; esac
  command -v br_cron_unlock >/dev/null 2>&1 && br_cron_unlock
  ck=$(br_cap_key "$p" "$rkey" "$tkey")
  slug=$(mc_slug_of_url "$url"); num=$(mc_num_of_url "$url"); key="$slug#$num"
  # rc 2 = GitHub did not answer (retried next tick); rc 1 = no head branch.
  ref=$(br_pr_ref "$url" "$slug"); rc=$?
  [ "$rc" = 0 ] || return 1
  read -r _ br head <<<"$ref"
  [ -n "$br" ] || return 1
  _brm_sha "$head" || return 1
  base=$(mc_project_base "$p"); repo="$REPOS/$p"
  _brm_repo "$p" "$slug" "$base" "$br" || return 1
  kind=$(br_conflict_kind "$repo" "origin/$base" "$head")
  case "$kind" in
    derived*)
      paths="${kind#derived }"
      if [ "${OBSERVE:-0}" = 1 ]; then
        say "$p/$rkey [$reason]: WOULD regen-rebase $br onto origin/$base — $paths is all that conflicts and this repo declares it generated or union-mergeable — observe mode"
        return 0
      fi
      _BRM_EX=$(_brm_exclfile "$repo" "origin/$base") || return 1
      _BRM_RG=$(_brm_regenfile "$repo" "origin/$base") || return 1
      # ON DISK, NOT tmpfs: /tmp on the hub is half of RAM and three worktrees
      # filled it to 99% (br_fix_round moved off it for the same reason).
      # mrt_rebase_pure mktemps its worktree under ${TMPDIR:-/tmp}.
      mkdir -p "$H/tmp/brmech" 2>/dev/null
      newhead=$(TMPDIR="$H/tmp/brmech" mrt_rebase_pure "$repo" "$MC_REMOTE" \
                  "origin/$base" "$br" "$head" "$_BRM_EX" "$_BRM_RG" "$p" "$url"); rc=$?
      case "$rc" in
        0)
          detail="rebased $br purely onto origin/$base and pushed ${newhead:0:8}; only $paths conflicted and this repo declares it generated or union-mergeable"
          # The push cannot be unsent, so a rebind that did not take is NAMED
          # rather than recorded as carried (mrt_carry_verdict swallows its rc).
          if ! job_verdict_rebind "$url" "$newhead" >/dev/null 2>&1; then
            detail="$detail — the ledger verdict did NOT rebind, so a re-review is still owed on the new head"
          fi
          mrt_carry_verdict "$rec" "$slug" "$p" "$num" "$url" "$newhead" "-" "$key"
          br_record "$p" "$ck" mechanical-regen "$reason" "$detail"
          br_event mechanical "$p" "$ck" "$reason" "$detail"
          br_count mechanical
          say "$p/$rkey [$reason]: MECHANICAL — $detail"
          return 0 ;;
        2) say "$p/$rkey [$reason]: $br rebases cleanly onto origin/$base but the rebased patch is NOT the same patch (a commit landed upstream, or a hunk was auto-merged) — nothing pushed, today's ladder owns it" ;;
        3) say "$p/$rkey [$reason]: $br rebases cleanly onto origin/$base but this repo's generated files do not settle on the result (${newhead:-?} still move after a regenerate and a commit) — a render with no fixed point is a real conflict wearing a clean rebase's clothes. Nothing pushed, today's ladder owns it" ;;
        4) say "$p/$rkey [$reason]: $br rebases onto origin/$base but Mergify holds the PR ($newhead) — nothing pushed (a push would dequeue it, BH-8623), today's ladder owns it" ;;
        *) say "$p/$rkey [$reason]: the pure rebase of $br onto origin/$base did not happen (rc $rc — a conflict, a worktree, or a refused push) — nothing pushed, today's ladder owns it" ;;
      esac
      return 1 ;;
    source*)
      # THE WHOLE conflicting set is the cluster, not just the path that stopped
      # the classifier — sorted and space-joined, so the key is a pure function
      # of the set and two parks compute the same one without talking.
      paths=$(_brm_mt "$repo" "origin/$base" "$head" | LC_ALL=C sort | paste -sd' ' -)
      [ -n "$paths" ] || return 1
      ckey=$(printf '%s' "$paths" | sha1sum 2>/dev/null | cut -c1-12)
      [ -n "$ckey" ] || return 1
      if [ "${OBSERVE:-0}" = 1 ]; then
        say "$p/$rkey [$reason]: WOULD cluster on $paths — observe mode"
        return 1
      fi
      br_set_field "$p" "$ck" conflict_cluster "$paths"
      br_set_field "$p" "$ck" conflict_cluster_key "$ckey"
      br_event conflict-clustered "$p" "$ck" "$reason" "conflicts on $paths (cluster $ckey)"
      # NOTHING WAS RESOLVED, so nothing is counted and today's ladder runs.
      return 1 ;;
    clean)
      # Main moved and this park now merges. The lane's own mechanical rung
      # merges origin/main and pushes; a second pusher here buys nothing.
      say "$p/$rkey [$reason]: $br no longer conflicts with origin/$base — leaving it to the lane's own mechanical rung"
      return 1 ;;
    *)
      say "$p/$rkey [$reason]: git could not compare ${head:0:8} with origin/$base — unknown is not clean, so today's ladder owns it"
      return 1 ;;
  esac
}
