#!/bin/bash
# shellcheck shell=bash
# bin/lib/archie-fm-repair.sh — BH-4585 (BH-4574.3): Archie's rebase-repair
# playbook, the 2026-10-04 hand fixes as code. Sourced by bin/archie-fm.sh after
# bin/lib/archie-fm.sh (whose afm_claim / afm_close / afm_cap_ok / afm_isolated /
# afm_suites it reuses), and by bin/blocked-resolver.sh for afm_first. Never
# run: no `set -e`, no `exit`, nothing at source time but assignments.
#
# WHAT IT ACTS ON (afm_rr_classify). A conductor park a merge of main could not
# get past: pr-state.tsv says BLOCKED_HUMAN with a reason that starts
# `conflict-unresolvable` or `rebase-gate-red`, on the PR's CURRENT head, on a
# PR whose base is the project's base. A `stacked child of parent=` park is the
# restack's (bin/lib/archie-fm.sh) and is left alone, and so is every other
# park (iron-law, red-ci-twice, prequeue-red, review): #4474, the conductor's
# own flake re-run and BH-4549 own those.
#
# THE PLAYBOOK (afm_rr_act), after the lane has claimed the action's row:
#   observe  close the row `would` / would_repair. No git at all.
#   on       a. a worktree of origin/<branch> (the hub clone, else the
#               conductor's scratch clone), the head still the one the list read;
#            b. `git merge --no-edit origin/<target>`;
#            c. EVERY conflicted path is tried (afm_rr_resolve_path): a deleted
#               but git-ignored file, a regenerated path (main's side, rendered
#               again in d), a per-ticket generated file, package.json test
#               scripts, an append-only union on the archie.fm.union_globs
#               allowlist (bin/lib/archie-fm-union.py: parse-validated, JSON
#               proven equal to a structural three-way merge), *.md union.
#               Anything left: `merge --abort`, NO push, and the row closes
#               `requested` / fix_round with a deterministic diagnosis that
#               bin/blocked-resolver.sh puts in the fix round's brief (afm_first);
#            d. generated-file drift regenerated IN PLACE (afm_rr_regen): the
#               commands main's Generated-files table and the archie.fm.regen
#               row declare, run as `nobody` in a snapshot (afm_isolated), their
#               declared paths carried back as a tar that is refused whole on a
#               symlink, a `..` or a path nobody declared;
#            e. the selected suites (afm_suites_flaky: a red made only of known
#               flakes, bin/lib/flaky.sh, is run ONCE more before it is blamed);
#            f. green: ONE hold_push with the lease on the listed head, then the
#               row closes done / repair. Red: requested / fix_round, no push.
#               Could not run: deferred, and wave 1's retry ladder takes it.
# No merge, no push to main (hold_push refuses it), no model call, no
# conductor write: an Archie push moves the head, and the conductor's
# hand-off park ends by itself when the head moves (mc_handoff_owns).
#
# Knobs are settings rows with the code default as the documented fallback:
# archie.cap.rebase-repair (10), archie.fm.union_globs, archie.fm.regen,
# archie.fm.first_s (1200). Note: docs/notes/2026-10-05-BH-4585-archie-fm-playbooks.md.
# gh-rest: no-graphql

AFM_RR_PY="${BASH_SOURCE[0]%/*}/archie-fm-union.py"
AFM_RR_CAP_DEFAULT=10
AFM_RR_GLOBS_DEFAULT='worker/*/src/index.js,worker/*/schema.sql,catalog/*.json,*.d/*'
AFM_RR_REGEN_DEFAULT='docs/config-inventory/deployment.md=bin/config-inventory.sh;docs/config-inventory/deployment.json=bin/config-inventory.sh'
AFM_RR_FIRST_S_DEFAULT=1200
AFM_RR_DIAG_MAX=6000

# afm_rr_setting <key> <default> -> the row's value (trimmed), or the default
#   when there is no row; an unreadable row is the default and one log line.
afm_rr_setting() {
  local v rc
  v=$(setting_get "$1"); rc=$?
  case "$rc" in
    0) v=$(printf '%s' "$v" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
       [ -n "$v" ] && { printf '%s' "$v"; return 0; } ;;
    2) ;;
    *) afm_log "warn: $1 unreadable (rc=$rc); using the default" ;;
  esac
  printf '%s' "$2"
}

# afm_rr_classify <project> <slug> <pr-json> -> rc 0 when the PR is a park this
#   playbook owns (see the header); sets AFM_RR_REASON and AFM_RR_SINCE.
afm_rr_classify() {
  local p="$1" slug="$2" pr="$3" n head base row st why
  AFM_RR_REASON=""; AFM_RR_SINCE=""
  n=$(jq -r '.number // ""' <<<"$pr"); head=$(jq -r '.head.sha // ""' <<<"$pr"); base=$(jq -r '.base.ref // ""' <<<"$pr")
  [[ $n =~ ^[0-9]+$ ]] && [[ $head =~ ^[0-9a-f]{40}$ ]] || return 1
  row=$(mc_row_get "$slug#$n")
  st=$(cut -f2 <<<"$row"); why=$(cut -f7 <<<"$row")
  [ "$st" = BLOCKED_HUMAN ] || return 1
  case "$why" in conflict-unresolvable*|rebase-gate-red*) ;; *) return 1 ;; esac
  case "$why" in *"stacked child of parent="*) return 1 ;; esac
  [ "$(cut -f4 <<<"$row")" = "$head" ] || return 1
  [ -n "$base" ] && [ "$base" = "$(mc_project_base "$p")" ] || return 1
  AFM_RR_REASON="$why"; AFM_RR_SINCE=$(cut -f3 <<<"$row")
  return 0
}

# afm_rr_one <project> <slug> <n> <mode> <branch> <head> <head-repo>
#   wave 1's one_pr skips, in its order, then the action under the conductor's
#   PR lock (flock -n on fd 8, held for the whole action; this lane never
#   waits). Sets AFM_RESULT: repaired | fix_round | would | deferred | noop |
#   failed | none (skipped, refused or unrecorded).
afm_rr_one() {
  local p="$1" slug="$2" n="$3" mode="$4" br="$5" head="$6" hrepo="$7" left
  AFM_RESULT=none
  if [ "$hrepo" != "$slug" ]; then
    afm_log "$slug#$n: the head lives in ${hrepo:-an unknown repo}, not $slug; this lane does not push it"; return 0
  fi
  if ! [[ $head =~ ^[0-9a-f]{40}$ ]] || [ -z "$br" ]; then
    afm_log "$slug#$n: the list read had no head sha or branch; skipped"; return 0
  fi
  if mc_hold_keeps_pr "$slug" "$n"; then afm_log "$slug#$n: the ticket is on HOLD; nothing done"; return 0; fi
  left=$(afm_time_left)
  if [ "$mode" = on ] && [ "$left" -lt $(( AFM_SUITE_TIMEOUT_S + AFM_TICK_SLACK_S )) ]; then
    afm_log "$slug#$n: ${left}s left in this tick, under a suite bound + slack ($((AFM_SUITE_TIMEOUT_S + AFM_TICK_SLACK_S))s); waits for the next tick"
    return 0
  fi
  exec 8>"$(mc_pr_lock "$p" "$n")" || return 0
  if ! flock -n 8; then
    exec 8>&-
    afm_log "$slug#$n: the conductor holds its PR lock; skipped this tick"; return 0
  fi
  afm_rr_act "$p" "$slug" "$n" "$mode" "$br" "$head"
  flock -u 8; exec 8>&-
  return 0
}

# afm_rr_act <project> <slug> <n> <mode> <branch> <head> — claim, then observe
#   or the playbook, then close the row. Sets AFM_RESULT (afm_rr_one).
afm_rr_act() {
  local p="$1" slug="$2" n="$3" mode="$4" br="$5" head="$6"
  # The wave-1 ledger helpers read these two; dynamic scope hands them ours.
  local AFM_PLAYBOOK=rebase-repair AFM_CAP_DEFAULT=$AFM_RR_CAP_DEFAULT
  local key ev rc target why
  AFM_RESULT=none
  target=$(mc_project_base "$p")
  key="$AFM_PLAYBOOK:$slug#$n:$head:$mode"
  ev=$(jq -nc --arg r "$AFM_RR_REASON" --arg s "$AFM_RR_SINCE" --arg h "$head" --arg t "$target" \
    '{park_reason: $r, park_since: $s, old_head: $h, onto: $t}')
  why="parked: ${AFM_RR_REASON:0:400}"
  if [ "$mode" = on ]; then
    afm_cap_ok "$p" || return 0
    afm_claim "$key" "$p" "$slug" "$n" on repair "$why" "$ev"; rc=$?
  else
    afm_claim "$key" "$p" "$slug" "$n" observe would_repair "$why" "$ev"; rc=$?
  fi
  [ "$rc" = 0 ] || return 0
  if [ "$mode" != on ]; then
    afm_close would would_repair \
      "would merge origin/$target into $br, resolve the append-only shapes, regenerate drift and run the suites (observe mode)" "$ev" || true
    afm_log "$slug#$n: would repair the park (${AFM_RR_REASON:0:80}); observe mode, nothing written"
    AFM_RESULT=would; return 0
  fi
  afm_rr_run "$p" "$slug" "$n" "$br" "$head" "$target"; rc=$?
  AFM_CUR_WT=""
  case "$rc" in
    0)
      ev=$(jq -c --arg nh "$AFM_RR_NEW" --arg sh "$AFM_RR_SHAPES" --arg rs "$AFM_RR_RESOLVED" --arg rg "$AFM_RR_REGENERATED" \
          --arg rf "$AFM_RR_REGEN_FAILED" --arg s "$AFM_SUITES" --arg fr "$AFM_FLAKY_RERUN" \
        '. + {new_head: $nh, shapes: ($sh | split(" ") | map(select(. != "")) | unique), resolved: ($rs | split(" ") | map(select(. != ""))),
              regenerated: ($rg | split(" ") | map(select(. != ""))), regen_failed: ($rf | split("\n") | map(select(. != ""))),
              suites: $s, flaky_rerun: ($fr | split(" ") | map(select(. != "")))}' <<<"$ev")
      afm_close done repair "merged origin/$target${AFM_RR_RESOLVED:+, resolved $AFM_RR_RESOLVED}${AFM_RR_REGENERATED:+, regenerated $AFM_RR_REGENERATED}; suites: ${AFM_SUITES:0:200}; pushed, CI pending" "$ev" || true
      afm_log "$slug#$n: repaired (merged origin/$target, ${AFM_RR_SHAPES:-clean merge}; ${AFM_RR_NEW:0:8}), pushed, CI pending"
      AFM_RESULT=repaired ;;
    1)
      afm_close done noop "$AFM_RR_WHY" "$(jq -c --arg s "$AFM_SUITES" '. + {suites: $s}' <<<"$ev")" || true
      afm_log "$slug#$n: $AFM_RR_WHY"
      AFM_RESULT=noop ;;
    2|3)
      ev=$(jq -c --arg d "${AFM_RR_DIAG:0:$AFM_RR_DIAG_MAX}" --arg u "$AFM_RR_UNRESOLVED" --arg s "$AFM_SUITES" --arg r "$AFM_SUITES_RED" \
          --arg fr "$AFM_FLAKY_RERUN" \
        '. + {diagnosis: $d, unresolved: ($u | split(" ") | map(select(. != ""))), suites: $s,
              suites_red: ($r | split(" ") | map(select(. != ""))), flaky_rerun: ($fr | split(" ") | map(select(. != "")))}' <<<"$ev")
      if [ "$rc" = 2 ]; then why="no playbook resolves $AFM_RR_UNRESOLVED; the diagnosis is the fix round's brief"
      else why="suites red after merging origin/$target: $AFM_SUITES_RED; the diagnosis is the fix round's brief"; fi
      afm_close requested fix_round "${why:0:500}" "$ev" || true
      afm_log "$slug#$n: $why; nothing pushed, bin/blocked-resolver.sh runs the fix round"
      AFM_RESULT=fix_round ;;
    *)
      afm_close deferred "" "${AFM_RR_WHY:0:500}" "$ev" || true
      afm_log "$slug#$n: deferred: $AFM_RR_WHY"
      AFM_RESULT=deferred ;;
  esac
  return 0
}

# afm_rr_checkout <project> <slug> <branch> <head> <target> -> rc 0 with
#   AFM_CUR_REPO/WT/CLONED set (afm_on_term cleans them) and MC_REMOTE armed;
#   else AFM_RR_WHY. Wave 1's afm_restack step a, copied, not shared: that
#   function is still under review on its own PR.
afm_rr_checkout() {
  local p="$1" slug="$2" br="$3" head="$4" target="$5" repo wt cloned="" remote ferr
  repo="${MC_REPOS:-/root/repos}/$p"
  mc_tmp_room "https://github.com/$slug" archie-fm || { AFM_RR_WHY="tmp full"; return 1; }
  mc_git_auth "$slug" || { mc_git_auth_clear; AFM_RR_WHY="no configured token can read $slug"; return 1; }
  remote="$MC_REMOTE"
  if [ -d "$repo/.git" ]; then
    wt=$(mktemp -d "${TMPDIR:-/tmp}/afm-repair-XXXX") || { mc_git_auth_clear; AFM_RR_WHY="mktemp failed"; return 1; }
    git -C "$repo" remote set-url origin "$remote" >/dev/null 2>&1 || true
    ferr=$(git -C "$repo" -c credential.helper= fetch -q origin "$target" "$br" 2>&1 >/dev/null) || {
      AFM_RR_WHY="fetch on the hub clone failed: $(mc_git_fail_line "$ferr")"; rm -rf "$wt"; mc_git_auth_clear; return 1; }
    ferr=$(git -C "$repo" worktree add -f --detach "$wt" "origin/$br" 2>&1 >/dev/null) || {
      AFM_RR_WHY="worktree add failed: $(mc_git_fail_line "$ferr")"; rm -rf "$wt"; mc_git_auth_clear; return 1; }
  else
    wt="$MC_H/tmp/conductor/${slug//\//_}"; mkdir -p "$(dirname "$wt")"; cloned=1
    if [ ! -d "$wt/.git" ]; then
      ferr=$(git -c credential.helper= clone -q --filter=blob:none "$remote" "$wt" 2>&1 >/dev/null) || {
        AFM_RR_WHY="scratch clone failed: $(mc_git_fail_line "$ferr")"; mc_git_auth_clear; return 1; }
    else
      git -C "$wt" remote set-url origin "$remote" >/dev/null 2>&1 || true
    fi
    ferr=$(git -C "$wt" -c credential.helper= fetch -q origin "$target" "$br" 2>&1 >/dev/null) || {
      AFM_RR_WHY="fetch on the scratch clone failed: $(mc_git_fail_line "$ferr")"; mc_git_auth_clear; return 1; }
    git -C "$wt" checkout -q --detach "origin/$br" 2>/dev/null || { AFM_RR_WHY="checkout failed"; mc_git_auth_clear; return 1; }
  fi
  AFM_CUR_REPO="$repo"; AFM_CUR_WT="$wt"; AFM_CUR_CLONED="$cloned"
  if [ "$(git -C "$wt" rev-parse HEAD 2>/dev/null)" != "$head" ]; then
    AFM_RR_WHY="the head moved since the list read it"; mc_rebase_cleanup "$repo" "$wt" "$cloned"; mc_git_auth_clear; return 1
  fi
  return 0
}

# afm_rr_union_match <path> — rc 0 when the path is on the union allowlist
#   (AFM_RR_GLOBS, a comma list; `*` crosses `/`, as in a case pattern).
afm_rr_union_match() {
  local g
  local -a gs=()
  # `read -a`, never an unquoted `for g in $AFM_RR_GLOBS`: that expanded each
  # glob against the current directory, so `worker/*/schema.sql` stopped
  # matching worker/jobs/schema.sql once the file left git (BH-6005).
  IFS=, read -r -a gs <<< "$AFM_RR_GLOBS"
  for g in "${gs[@]}"; do
    g=$(printf '%s' "$g" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    [ -n "$g" ] || continue
    # shellcheck disable=SC2254
    case "$1" in $g) return 0 ;; esac
  done
  return 1
}

# afm_rr_resolve_path <worktree> <path> <ticket-key> -> rc 0 resolved and
#   staged (AFM_RR_SHAPE says how), rc 1 not (AFM_RR_NOTE says why). The
#   conductor's own resolvers first, in mc_resolve_conflicts' order, EXCEPT a
#   regenerated path: mc_resolve_by_regen runs the PR's generator as root, so
#   here main's side is taken and the path is rendered again by afm_rr_regen.
afm_rr_resolve_path() {
  local wt="$1" f="$2" mine="$3" out rc errf cmd
  AFM_RR_SHAPE=""; AFM_RR_NOTE=""
  if mc_resolve_deleted_ignored "$wt" "$f"; then AFM_RR_SHAPE=deleted-ignored; return 0; fi
  # BH-6000: the same rule as mc_resolve_conflicts. A registered render whose
  # generator is not in the merged tree (worker/jobs/schema.sql in a tree
  # without bin/schema-build.sh) is not the regenerate's to settle: taking
  # main's side there with nothing to re-render drops the branch's own rows.
  # An append-union path falls through to the union step it took before; any
  # other registered path keeps the regenerate (BH-1162: never a union).
  if cmd=$(mc_regen_cmd_for_path "$f") \
     && { [ -x "$wt/${cmd%% *}" ] || ! command -v mc_path_is_union >/dev/null 2>&1 || ! mc_path_is_union "$f"; }; then
    if git -C "$wt" checkout --theirs -- "$f" >/dev/null 2>&1 && git -C "$wt" add -- "$f" >/dev/null 2>&1; then
      AFM_RR_REGEN_Q="$AFM_RR_REGEN_Q$f"$'\n'; AFM_RR_SHAPE=regenerate; return 0
    fi
    AFM_RR_NOTE="a regenerated path (config/regenerated-paths.conf) with no origin side to take"; return 1
  fi
  if mc_resolve_generated "$wt" "$f" "$mine"; then AFM_RR_SHAPE=generated; return 0; fi
  if [ "$f" = package.json ]; then
    if ( cd "$wt" && mc_resolve_package_json ) >/dev/null 2>&1 && git -C "$wt" add -- "$f" >/dev/null 2>&1; then
      AFM_RR_SHAPE=package-json; return 0
    fi
    AFM_RR_NOTE="package.json: not a test-script list both sides appended to"; return 1
  fi
  if afm_rr_union_match "$f"; then
    errf=$(mktemp "${TMPDIR:-/tmp}/afm-union.XXXXXX") || { AFM_RR_NOTE="mktemp failed"; return 1; }
    out=$(python3 "$AFM_RR_PY" resolve "$wt" "$f" 2>"$errf"); rc=$?
    if [ "$rc" = 0 ] && git -C "$wt" add -- "$f" >/dev/null 2>&1; then
      rm -f "$errf"; AFM_RR_SHAPE=${out#shape=}; return 0
    fi
    AFM_RR_NOTE="on the union allowlist, but $(head -1 "$errf" | cut -c1-300)"
    [ "$rc" = 1 ] || AFM_RR_NOTE="the union tool could not run (rc $rc): $(head -1 "$errf" | cut -c1-300)"
    rm -f "$errf"; return 1
  fi
  case "$f" in
    *.md)
      if ( cd "$wt" && mc_resolve_md_union "$f" ) >/dev/null 2>&1 && git -C "$wt" add -- "$f" >/dev/null 2>&1; then
        AFM_RR_SHAPE=md-union; return 0
      fi
      AFM_RR_NOTE="markdown union refused"; return 1 ;;
  esac
  AFM_RR_NOTE="path not on the union allowlist (archie.fm.union_globs)"
  return 1
}

# afm_rr_regen_rows <worktree> <target> -> `<path>\t<command>` per line: main's
#   Generated-files table, the archie.fm.regen row, and the regenerated paths a
#   conflict queued (AFM_RR_REGEN_Q). Never a command out of the PR's own diff.
afm_rr_regen_rows() {
  local wt="$1" target="$2" spec pair f cmd
  mc_regen_table "$wt" "origin/$target"
  spec=$(afm_rr_setting archie.fm.regen "$AFM_RR_REGEN_DEFAULT")
  local IFS=';'
  for pair in $spec; do
    case "$pair" in *=*) printf '%s\t%s\n' "${pair%%=*}" "${pair#*=}" ;; esac
  done
  IFS=$'\n'
  for f in $AFM_RR_REGEN_Q; do
    cmd=$(mc_regen_cmd_for_path "$f") && printf '%s\t%s\n' "$f" "$cmd"
  done
}

# afm_rr_stamp_only <worktree> <path>... — a regenerated .json whose only change
#   from HEAD is its `generated_at_commit` is put back to HEAD's copy. The
#   snapshot afm_isolated runs in is a throwaway commit, so bin/config-inventory.py
#   stamps a sha main never has: kept, it is a "regenerate" commit on every repair
#   and a line-2 conflict with main once one of them merges. The same field
#   tests/no-hardcoded-deployment.bh-4080-test.sh's R1 ignores.
afm_rr_stamp_only() {
  local wt="$1" p old new; shift
  for p in "$@"; do
    case "$p" in *.json) ;; *) continue ;; esac
    old=$(git -C "$wt" show "HEAD:$p" 2>/dev/null | jq -S 'del(.generated_at_commit?)' 2>/dev/null) || continue
    new=$(jq -S 'del(.generated_at_commit?)' "$wt/$p" 2>/dev/null) || continue
    [ -n "$old" ] && [ "$old" = "$new" ] && git -C "$wt" checkout -q HEAD -- "$p" >/dev/null 2>&1
  done
  return 0
}

# afm_rr_regen <worktree> <target> — generated-file drift regenerated IN PLACE.
#   Each distinct command runs once through afm_isolated (a snapshot of the
#   merged tree, as nobody, env -i, bounded by the suite knob or the time left)
#   as `<cmd> && tar` of ITS declared paths, and only a declared path that is
#   tracked in the merged tree counts (an ignored render commits nothing). The
#   tar comes back to root through archie-fm-union.py untar, which refuses the
#   whole archive on anything but plain files and directories under a declared
#   path. A failing command is evidence (AFM_RR_REGEN_FAILED), never a failed
#   action: nothing of it reaches the tree, and the suites and CI stay the
#   arbiters (mc_regen_generated's contract). Commits once when the index moved.
afm_rr_regen() {
  local wt="$1" target="$2" rows cmds cmd paths p outd errf rc bound left name email as=nobody
  local -a pv
  AFM_RR_REGENERATED=""; AFM_RR_REGEN_FAILED=""
  [ "${HARNESS_TEST_SANDBOX:-}" = 1 ] && [ "${ARCHIE_FM_SUITE_AS:-}" = self ] && as=self
  rows=$(afm_rr_regen_rows "$wt" "$target" | awk -F'\t' 'NF >= 2 && $1 != "" && $2 != "" && !seen[$0]++')
  [ -n "$rows" ] || return 0
  cmds=$(cut -f2- <<<"$rows" | awk '!seen[$0]++')
  while IFS= read -r cmd; do
    [ -n "$cmd" ] || continue
    pv=()
    while IFS= read -r p; do
      case "$p" in *'*'*|*'?'*|*'['*|/*|*..*) continue ;; esac
      git -C "$wt" ls-files --error-unmatch -- "$p" >/dev/null 2>&1 || continue
      pv+=("$p")
    done < <(awk -F'\t' -v c="$cmd" '{ k = $1; sub(/^[^\t]*\t/, ""); if ($0 == c) print k }' <<<"$rows" | awk '!seen[$0]++')
    [ "${#pv[@]}" -gt 0 ] || continue
    left=$(( $(afm_time_left) - 60 )); bound=$AFM_SUITE_TIMEOUT_S
    [ "$left" -lt "$bound" ] && bound=$left
    if [ "$bound" -le 0 ]; then AFM_RR_REGEN_FAILED="$AFM_RR_REGEN_FAILED$cmd (no time left in the tick)"$'\n'; continue; fi
    outd=$(mktemp -d "${TMPDIR:-/tmp}/afm-regen-XXXXXX") || { AFM_RR_REGEN_FAILED="$AFM_RR_REGEN_FAILED$cmd (mktemp failed)"$'\n'; continue; }
    errf="$outd.log"; : > "$errf"
    if [ "$as" = nobody ]; then chown nobody "$outd" 2>/dev/null; fi
    chmod 700 "$outd"
    # shellcheck disable=SC2016
    afm_isolated "$wt" "$target" "$errf" "$bound" bash -c \
      'o=$1; c=$2; shift 2; ( eval "$c" ) </dev/null && tar -cf "$o/out.tar" -- "$@"' _ "$outd" "$cmd" "${pv[@]}"
    rc=$?
    if [ "$rc" = 0 ] && [ -f "$outd/out.tar" ]; then
      if python3 "$AFM_RR_PY" untar "$outd/out.tar" "$wt" "${pv[@]}" 2>>"$errf"; then
        afm_rr_stamp_only "$wt" "${pv[@]}"
        git -C "$wt" add -A -- "${pv[@]}" >/dev/null 2>&1
        AFM_RR_REGENERATED="$AFM_RR_REGENERATED ${pv[*]}"
      else
        AFM_RR_REGEN_FAILED="$AFM_RR_REGEN_FAILED$cmd (output refused: $(tail -1 "$errf" | cut -c1-200))"$'\n'
        git -C "$wt" checkout -q -- "${pv[@]}" >/dev/null 2>&1
      fi
    else
      AFM_RR_REGEN_FAILED="$AFM_RR_REGEN_FAILED$cmd (rc $rc: $(tail -1 "$errf" | cut -c1-200))"$'\n'
      afm_log "regenerate FAILED: $cmd (rc $rc); nothing of it reaches the tree"
    fi
    rm -rf "$outd" "$errf"
  done <<<"$cmds"
  AFM_RR_REGENERATED=$(tr ' ' '\n' <<<"$AFM_RR_REGENERATED" | awk 'NF && !seen[$0]++' | tr '\n' ' ' | sed 's/ *$//')
  git -C "$wt" diff --cached --quiet >/dev/null 2>&1 && { AFM_RR_REGENERATED=""; return 0; }
  name=${MC_GIT_NAME:-$HARNESS_MERGE_GIT_NAME}; email=${MC_GIT_EMAIL:-$HARNESS_GIT_EMAIL}
  if git -C "$wt" -c user.name="$name" -c user.email="$email" -c commit.gpgsign=false \
       commit -q -m "regenerate $AFM_RR_REGENERATED (archie-fm)" >/dev/null 2>&1; then
    AFM_RR_SHAPES="$AFM_RR_SHAPES regenerate"
  else
    AFM_RR_REGEN_FAILED="${AFM_RR_REGEN_FAILED}the regenerated files would not commit"$'\n'; AFM_RR_REGENERATED=""
    git -C "$wt" reset -q --hard HEAD >/dev/null 2>&1
  fi
  return 0
}

# afm_suites_flaky <worktree> <target> <outfile> <slug> -> afm_suites' rc. A red
#   whose every suite is in flaky_gate_set (bin/lib/flaky.sh) is run ONCE more
#   before it is blamed; AFM_FLAKY_RERUN names what was re-run. A set that
#   cannot be read is empty, so there is no re-run and the red stands.
afm_suites_flaky() {
  local wt="$1" target="$2" out="$3" slug="$4" rc first
  AFM_FLAKY_RERUN=""
  afm_suites "$wt" "$target" "$out"; rc=$?
  [ "$rc" = 1 ] && [ -n "$AFM_SUITES_RED" ] || return "$rc"
  command -v flaky_all_known >/dev/null 2>&1 || return 1
  tr ' ' '\n' <<<"$AFM_SUITES_RED" | flaky_all_known "$slug" 2>/dev/null || return 1
  AFM_FLAKY_RERUN="$AFM_SUITES_RED"; first="$AFM_SUITES"
  afm_log "$slug: suites red only on known flakes ($AFM_SUITES_RED); running them once more before blaming them"
  afm_suites "$wt" "$target" "$out"; rc=$?
  case "$rc" in
    0) AFM_SUITES="$first; flaky re-run: green: $AFM_SUITES" ;;
    1) AFM_SUITES="$first; flaky re-run: still red: $AFM_SUITES" ;;
  esac
  return "$rc"
}

# afm_rr_run <project> <slug> <n> <branch> <head> <target> — the on-mode steps
#   a-f. rc 0 pushed (AFM_RR_NEW) | 1 noop (AFM_RR_WHY) | 2 unresolved paths
#   (AFM_RR_UNRESOLVED, AFM_RR_DIAG) | 3 suites red (AFM_RR_DIAG) | 4 deferred,
#   could not run (AFM_RR_WHY). Never pushes anything but rc 0.
afm_rr_run() {
  local p="$1" slug="$2" n="$3" br="$4" head="$5" target="$6"
  local repo wt cloned remote merr rc f conf src new mine name email diag
  AFM_RR_WHY=""; AFM_RR_NEW=""; AFM_RR_SHAPES=""; AFM_RR_RESOLVED=""; AFM_RR_UNRESOLVED=""; AFM_RR_DIAG=""
  AFM_RR_REGEN_Q=""; AFM_RR_REGENERATED=""; AFM_RR_REGEN_FAILED=""; AFM_FLAKY_RERUN=""
  AFM_SUITES=""; AFM_SUITES_RED=""; AFM_PROJECT="$p"
  AFM_RR_GLOBS=$(afm_rr_setting archie.fm.union_globs "$AFM_RR_GLOBS_DEFAULT")
  afm_rr_checkout "$p" "$slug" "$br" "$head" "$target" || return 4
  repo="$AFM_CUR_REPO"; wt="$AFM_CUR_WT"; cloned="$AFM_CUR_CLONED"; remote="$MC_REMOTE"
  name=${MC_GIT_NAME:-$HARNESS_MERGE_GIT_NAME}; email=${MC_GIT_EMAIL:-$HARNESS_GIT_EMAIL}
  # b. merge main. Two-way markers on purpose: mc_resolve_md_union reads them.
  # >>> afm rr merge
  merr=$(git -C "$wt" -c user.name="$name" -c user.email="$email" -c commit.gpgsign=false -c merge.conflictStyle=merge \
           merge --no-edit "origin/$target" 2>&1 >/dev/null)
  rc=$?
  # <<< afm rr merge
  if [ "$rc" != 0 ]; then
    conf=$(git -C "$wt" diff --name-only --diff-filter=U 2>/dev/null)
    if [ -z "$conf" ]; then
      git -C "$wt" merge --abort >/dev/null 2>&1
      mc_rebase_cleanup "$repo" "$wt" "$cloned"; mc_git_auth_clear
      AFM_RR_WHY="git merge origin/$target refused with no conflicted path: $(mc_git_err_line "${merr:-(no stderr)}")"; return 4
    fi
    # c. EVERY path is tried, so the diagnosis can name all of them.
    mine=$(mc_ticket_of_branch "$br" 2>/dev/null) || mine=""
    diag=""
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      if afm_rr_resolve_path "$wt" "$f" "$mine"; then
        AFM_RR_RESOLVED="$AFM_RR_RESOLVED $f"; AFM_RR_SHAPES="$AFM_RR_SHAPES $AFM_RR_SHAPE"
      else
        AFM_RR_UNRESOLVED="$AFM_RR_UNRESOLVED $f"
        diag="$diag"$'\n'"$(python3 "$AFM_RR_PY" diagnose "$wt" "$f" "$AFM_RR_NOTE" 2>/dev/null || printf -- '--- %s ---\nshape: %s\n' "$f" "$AFM_RR_NOTE")"
      fi
    done <<<"$conf"
    AFM_RR_RESOLVED=${AFM_RR_RESOLVED# }; AFM_RR_UNRESOLVED=${AFM_RR_UNRESOLVED# }; AFM_RR_SHAPES=${AFM_RR_SHAPES# }
    if [ -n "$AFM_RR_UNRESOLVED" ]; then
      git -C "$wt" merge --abort >/dev/null 2>&1
      mc_rebase_cleanup "$repo" "$wt" "$cloned"; mc_git_auth_clear
      AFM_RR_DIAG="Merging origin/$target into $br leaves $(wc -w <<<"$AFM_RR_UNRESOLVED" | tr -d ' ') path(s) none of Archie's playbooks resolves (an append-only union, a regenerate, a generated file): $AFM_RR_UNRESOLVED.${AFM_RR_RESOLVED:+ Resolved mechanically and NOT part of this brief: $AFM_RR_RESOLVED.}$diag"
      AFM_RR_DIAG=${AFM_RR_DIAG:0:$AFM_RR_DIAG_MAX}
      return 2
    fi
    if ! git -C "$wt" -c user.name="$name" -c user.email="$email" -c commit.gpgsign=false commit -q --no-edit >/dev/null 2>&1; then
      git -C "$wt" merge --abort >/dev/null 2>&1
      mc_rebase_cleanup "$repo" "$wt" "$cloned"; mc_git_auth_clear
      AFM_RR_WHY="the resolved merge would not commit"; return 4
    fi
  fi
  # d. drift, then e. the suites. The token is disarmed first and re-armed only
  #    for the push: both run PR code (as nobody, under env -i).
  mc_git_auth_clear
  afm_rr_regen "$wt" "$target"
  src=$(mktemp "${TMPDIR:-/tmp}/afm-suites.XXXXXX") || { mc_rebase_cleanup "$repo" "$wt" "$cloned"; AFM_RR_WHY="mktemp failed"; return 4; }
  afm_suites_flaky "$wt" "$target" "$src" "$slug"; rc=$?
  rm -f "$src"
  case "$rc" in
    0) ;;
    1) mc_rebase_cleanup "$repo" "$wt" "$cloned"
       AFM_RR_DIAG="The merge of origin/$target into $br is clean${AFM_RR_RESOLVED:+ after Archie resolved $AFM_RR_RESOLVED}, and these suites are red on the merged tree: $AFM_SUITES_RED.${AFM_FLAKY_RERUN:+ They are known flakes and were re-run once: still red.} Suites: $AFM_SUITES"
       AFM_RR_DIAG=${AFM_RR_DIAG:0:$AFM_RR_DIAG_MAX}
       return 3 ;;
    *) mc_rebase_cleanup "$repo" "$wt" "$cloned"; AFM_RR_WHY="the suites could not run: $AFM_SUITES"; return 4 ;;
  esac
  new=$(git -C "$wt" rev-parse HEAD)
  if [ "$new" = "$head" ]; then
    mc_rebase_cleanup "$repo" "$wt" "$cloned"
    AFM_RR_WHY="the branch already contains origin/$target, nothing needed regenerating, and the suites are green: nothing to push"; return 1
  fi
  # f. ONE push, with the lease on the head the list read.
  mc_git_auth "$slug" || { mc_rebase_cleanup "$repo" "$wt" "$cloned"; AFM_RR_WHY="no configured token can push $slug; nothing pushed"; return 4; }
  remote="$MC_REMOTE"
  # >>> afm rr push
  if ! { mc_hold_push_load && HOLD_PUSH_LOG="${AFM_LOG:-}" hold_push -n "$p" - "$wt" "$remote" HEAD "$br" "$head" >/dev/null 2>&1; }; then
    mc_rebase_cleanup "$repo" "$wt" "$cloned"; mc_git_auth_clear
    AFM_RR_WHY="the push was refused (lease or hold); nothing pushed"; return 4
  fi
  # <<< afm rr push
  mc_rebase_cleanup "$repo" "$wt" "$cloned"; mc_git_auth_clear
  AFM_RR_NEW="$new"
  return 0
}

# afm_first <project> <slug> <num> <head> — bin/blocked-resolver.sh asks this
#   before it spends a fix round on a park, so the playbooks run first and their
#   diagnosis becomes the round's brief. A bounded defer, never a wait:
#   rc 1  not Archie's: carry on as today. The park is not one this playbook
#         owns, the mode is not `on`, the settings or the route cannot be read,
#         the row failed or ended without a push, or there is no row and the
#         park is older than archie.fm.first_s (0 = never wait).
#         Also rc 1: the archie-fm lane is switched off (ARCHIE_FM_ENABLED=0,
#         flags/lane-off-archie-fm or all-off through lane_paused), since
#         nothing would ever finish the repair, and a row started or deferred
#         whose updated_at is older than max(first_s, ARCHIE_FM_RETRY_S) +
#         first_s or cannot be read: Archie's retry ladder only runs inside
#         its own tick, so a row it stopped revisiting must not hold the park.
#   rc 3  Archie is on this head: offer the park again next tick. No row yet
#         and the park is younger than first_s; a row started or deferred
#         younger than that bound; a row done / repair younger than first_s
#         (Archie pushed, so this head is stale and the park ends when the
#         conductor sees the new one).
#   rc 0  a row `requested`: stdout is its diagnosis.
afm_first() {
  local p="$1" slug="$2" num="$3" head="$4" row st why since mode first now key f rc out act upd ts retry
  command -v mc_row_get >/dev/null 2>&1 && command -v setting_get >/dev/null 2>&1 || return 1
  row=$(mc_row_get "$slug#$num")
  st=$(cut -f2 <<<"$row"); why=$(cut -f7 <<<"$row"); since=$(cut -f3 <<<"$row")
  [ "$st" = BLOCKED_HUMAN ] || return 1
  case "$why" in conflict-unresolvable*|rebase-gate-red*) ;; *) return 1 ;; esac
  case "$why" in *"stacked child of parent="*) return 1 ;; esac
  [[ $head =~ ^[0-9a-f]{40}$ ]] && [ "$(cut -f4 <<<"$row")" = "$head" ] || return 1
  mode=$(afm_mode "$p") || return 1
  [ "$mode" = on ] || return 1
  [ "${ARCHIE_FM_ENABLED:-1}" = 0 ] && return 1
  if command -v lane_paused >/dev/null 2>&1 && lane_paused archie-fm; then return 1; fi
  first=$(afm_rr_setting archie.fm.first_s "$AFM_RR_FIRST_S_DEFAULT")
  if ! [[ $first =~ ^[0-9]+$ ]] || [ "$((10#$first))" -gt 86400 ]; then
    afm_log "warn: archie.fm.first_s='$first' is not 0..86400; using the default $AFM_RR_FIRST_S_DEFAULT"
    first=$AFM_RR_FIRST_S_DEFAULT
  fi
  first=$((10#$first))
  now=$(date -u +%s)
  if [ "${HARNESS_TEST_SANDBOX:-}" = 1 ] && [[ ${ARCHIE_FM_NOW:-} =~ ^[0-9]+$ ]]; then now=$ARCHIE_FM_NOW; fi
  key=$(jq -rn --arg k "rebase-repair:$slug#$num:$head:on" '$k | @uri')
  f=$(mktemp "${TMPDIR:-/tmp}/afm-first.XXXXXX") || return 1
  _jobs_req GET "/api/archie/actions?dedupe_key=$key" > "$f"; rc=$?
  out=$(cat "$f"); rm -f "$f"
  case "$rc" in
    0) ;;
    2)
      # A missing row is the route's own 404 answer; any other 404 is a worker
      # without the route, which is not Archie's to wait on.
      case "${JOBS_BODY:-}" in *"archie action not found"*) ;; *) return 1 ;; esac
      [ "$first" -gt 0 ] && [[ $since =~ ^[0-9]+$ ]] && [ $((now - since)) -lt "$first" ] && return 3
      return 1 ;;
    *) return 1 ;;
  esac
  st=$(jq -r '.action.outcome // ""' <<<"$out" 2>/dev/null); act=$(jq -r '.action.action // ""' <<<"$out" 2>/dev/null)
  case "$st" in
    requested)
      jq -r '.action.evidence.diagnosis // .action.why // empty' <<<"$out" 2>/dev/null
      return 0 ;;
    started|deferred)
      retry=${ARCHIE_FM_RETRY_S:-1800}
      [[ $retry =~ ^[0-9]+$ ]] && [ "$((10#$retry))" -ge 60 ] && [ "$((10#$retry))" -le 86400 ] || retry=1800
      retry=$((10#$retry)); [ "$retry" -lt "$first" ] && retry=$first
      upd=$(jq -r '.action.updated_at // ""' <<<"$out" 2>/dev/null)
      ts=""; [ -n "$upd" ] && ts=$(date -u -d "$upd" +%s 2>/dev/null)
      [[ $ts =~ ^[0-9]+$ ]] && [ $((now - ts)) -lt $((retry + first)) ] && return 3
      return 1 ;;
    done)
      [ "$act" = repair ] || return 1
      upd=$(jq -r '.action.updated_at // ""' <<<"$out" 2>/dev/null)
      ts=""; [ -n "$upd" ] && ts=$(date -u -d "$upd" +%s 2>/dev/null)
      [[ $ts =~ ^[0-9]+$ ]] && [ $((now - ts)) -lt "$first" ] && return 3
      return 1 ;;
    *) return 1 ;;
  esac
}
