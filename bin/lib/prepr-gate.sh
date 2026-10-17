#!/bin/bash
# bin/lib/prepr-gate.sh — BH-1706: the pre-PR gate bin/run-build.sh runs at the
# EXECUTE -> PR boundary. Sourced, never executed. Defines functions only.
#
# WHY. cromford CI runs two deterministic gates on every PR:
# `bin/checks-run.sh --tree .` and `bin/test-determinism-lint.sh`. The build
# already runs checks-run in DIFF mode (the MINED CHECKS block), but diff mode
# drops every tests/ path, so a test that rm -rf's a path it does not own, or
# reads the wall clock, sailed through the build and went red one CI round
# later. Here the build runs the same two commands CI runs, and a finding in a
# file this build changed buys the execute agent ONE bounded fix turn before
# the PR exists.
#
# BH-2414 added CI's third gate, `bin/test-impact.sh orphans --check`: three
# pool PRs on 2026-09-25 opened red on it (new console-ui files only a node test
# imported) while this gate passed them.
#
# prepr_scan <wt> <base> <out-dir>
#   Runs the gates on <wt>, keeps their raw output (checks.txt,
#   determinism.txt, orphans.txt) and splits the findings by the build's own
#   diff: prepr-findings.txt (in a file <base>...HEAD changed, and every
#   ORPHAN, which is new against the base by construction) and
#   prepr-preexisting.txt (anywhere else — never this build's to fix).
#   A repo without bin/test-impact.sh skips the ratchet alone.
#   rc 0 clean, 1 in-diff findings, 2 could not run, 3 skipped (the repo ships
#   neither gate, so there is nothing CI would run either).
#
# prepr_gate <wt> <base> <build>
#   Scan; on in-diff findings, one `CC fix "$FIX_MODEL" 4800` turn with the
#   findings verbatim as the brief; re-scan once. Sets PREPR_STATE
#   (clean|fixed|red|could-not-run|skipped|off), PREPR_NOTE (" | prepr=red" or
#   empty) and PREPR_SECTION (the PR body's "Pre-PR gate: unresolved" section or
#   empty). Writes <build>/prepr.txt and one `PREPR state=` pipeline.log line.
#   The number of turns is the registry knob RB_PREPR_FIX_TURNS on the fly-pool
#   lane (bin/lib/lane-gate.sh: settings row > env > registry default); an
#   unreadable registry is detection only, and more than one is one.
#   Records the head it judged in <build>/prepr-head.
#   Also sets PREPR_PACK_STATE (clean|red|could-not-run|skipped, see the rules
#   pack below) and writes it as `pack=` in prepr.txt and at the end of the
#   `PREPR state=` line.
#
# THE RULES PACK (BH-3513, BH-3477.4). prepr_scan also runs bin/rules-pack.sh
#   (contract in its header, BH-3509) with --skip checks-tree,determinism (the
#   two gates above already ran). Each stdout line becomes an in-diff finding
#   `RULES-PACK <id>: <line>` and shares the one fix turn; pre-existing lines go
#   to prepr-preexisting.txt. rc 1 with no line, 2, 124 (timeout, 3x the
#   budget), 125 or anything else is could-not-run and never changes the scan's
#   own rc. No executable pack in the repo is `skipped`. PREPR_PACK_STATE is red
#   when a RULES-PACK line survives the fix turn, when the turn edited a pack
#   rules path, or when a pack that was red could not re-run after the turn.
#   The late pass keeps the first pass's value when its own pack could not run.
#
# THE CI LINT JOB (BH-6897). After the pack, prepr_scan runs the tree's own
#   bin/ci-local.sh --skip-rules-pack through cl_run (bin/lib/ci-local-verify.sh):
#   the steps of CI's lint and determinism jobs, read from the workflow. Each
#   line of its findings.txt is an in-diff finding `CI-LOCAL <job> / <step>: …`
#   (ci-local already set aside the steps that are red on the base too) and
#   shares the one fix turn. Still present after the turn, or the turn edited
#   ci-local's own rules, or a red ci-local could not re-run: PREPR_LINT_STATE
#   is red, so rules_pack_block stops the build like a fast-lint line. A
#   could-not-run, skipped (no bin/ci-local.sh) or off (CI_LOCAL_GATE=0) run
#   changes nothing. PREPR_SCAN_CILOCAL holds the word; `cilocal=` in
#   prepr.txt and a separate `PREPR <label>ci-local=` log line record it.
#
# rules_pack_block <where>
#   Called at `# >>> rules pack block` in bin/lib/rb/execute.sh (after the push,
#   before the reviewer) and bin/lib/rb/pr.sh (after the late pass, before PR
#   create). PREPR_PACK_STATE=red and RULES_PACK_BLOCK (fly-pool knob, BH-3509)
#   1 or unresolved: writes <build>/rules-pack-block.txt, one alert through
#   bin/alert-line.sh, escalate_block, RESULT `REVIEW_BLOCKED rules-pack: ...`
#   and exit 6. RULES_PACK_BLOCK=0 is warn only: one log line, and the PR opens
#   with the "Pre-PR gate: unresolved" section.
#
# rules_pack_budget
#   The resolved RULES_PACK_BUDGET_S (fly-pool knob), or 60. Also read by
#   HARNESS_IMPACT_GATE_RUN in bin/lib/rb/gates.sh.
#
# prepr_gate_late <wt> <base> <build>   (BH-2021)
#   The same pass on the head the PR opens with, after the review fix rounds
#   and the pre-PR rebase; artifacts under <build>/prepr-late/, one
#   `PREPR late state=` line. Skipped (`unchanged`) when that head is the one
#   already judged. The fix turn is shared with the first pass.
#
# prepr_body_keywords   (stdin -> stdout)
#   A child slice's PR must not close its parent. For every `Part of #N` line
#   in $BUILD/ticket-meta.json's body or $BUILD/plan.md, any GitHub closing
#   keyword immediately before `#N` becomes `Part of #N`. No parent, or no
#   ticket-meta.json: the text passes through byte for byte. No model.

_PREPR_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/lib/ci-local-verify.sh
[ -r "$_PREPR_LIB_DIR/ci-local-verify.sh" ] && . "$_PREPR_LIB_DIR/ci-local-verify.sh"

# The paths that define the CI-LOCAL findings: a fix turn must not edit them.
_PREPR_CL_RULES='^(bin/ci-local\.sh|bin/ci-local-plan\.py|bin/lib/ci-local-verify\.sh|catalog/ci-local-skip\.d/.*|\.github/workflows/harness-ci\.yml)$'

# _prepr_log <build> <line>
_prepr_log() {
  local s
  if command -v STAMP >/dev/null 2>&1; then s=$(STAMP); else s=$(date -u '+%Y-%m-%d %H:%M:%SZ'); fi
  printf '%s [%s/%s] %s\n' "$s" "${PROJECT:-?}" "${KEY:-?}" "$2" >> "$1/pipeline.log"
}

# _prepr_path <wt-abs> <path> — strip ./ and the worktree prefix.
_prepr_path() {
  local p="$2"
  p="${p#"$1"/}"
  while [ "${p#./}" != "$p" ]; do p="${p#./}"; done
  printf '%s' "$p"
}

# _prepr_orphans <wt-abs> <base> <out> — BH-2414. CI's orphan ratchet, the same
# command harness-ci.yml runs (tests/rb-prepr-orphans.bh-2414-test.sh O7 diffs
# the two), from the repo root. CI sets TI_BASE to the PR's base sha and checks
# out the merge ref, whose first parent that is; here the equivalent base is the
# build's merge-base with <base>, the same one `<base>...HEAD` lists files from.
# Writes <out>/orphans.txt (raw) and <out>/orphans-findings.txt, one
# `ORPHAN <path> <reason>` line per new orphan. rc 0 judged (findings or none,
# or skipped when the repo ships no ratchet), rc 1 could not run.
_prepr_orphans() {
  local wta="$1" base="$2" out="$3" tib orc
  : > "$out/orphans-findings.txt"
  if [ ! -x "$wta/bin/test-impact.sh" ]; then
    echo "orphans: skipped (repo ships no bin/test-impact.sh)" >> "$out/prepr-scan.txt"
    return 0
  fi
  if ! tib=$(git -C "$wta" merge-base "$base" HEAD 2>>"$out/prepr-scan.txt"); then
    echo "prepr: could not run (no merge-base with $base for the orphan ratchet)" >> "$out/prepr-scan.txt"
    return 1
  fi
  ( cd "$wta" && TI_BASE="$tib" timeout 600 bin/test-impact.sh orphans --check ) > "$out/orphans.txt" 2>&1; orc=$?
  echo "orphans rc=$orc base=$tib" >> "$out/prepr-scan.txt"
  if [ "$orc" -ge 2 ]; then
    echo "prepr: could not run (the orphan ratchet exited $orc or timed out)" >> "$out/prepr-scan.txt"
    return 1
  fi
  [ "$orc" = 0 ] && return 0
  awk '
    / is TRACKED in git/ { print "ORPHAN " $2 " is TRACKED in git; the list is derived: git rm --cached it (bin/test-impact.sh orphans --check)"; next }
    /this diff adds [0-9]+ orphan/ { f = 1; next }
    f && /^test-impact:   [^ ]+$/ { print "ORPHAN " $2 " is named by no tests/*.sh suite (bin/test-impact.sh orphans --check)"; next }
    { f = 0 }' "$out/orphans.txt" > "$out/orphans-findings.txt"
  if [ ! -s "$out/orphans-findings.txt" ]; then
    echo "prepr: could not run (the orphan ratchet reported findings this scan could not parse)" >> "$out/prepr-scan.txt"
    return 1
  fi
  return 0
}

prepr_scan() {
  local wt="$1" base="$2" out="$3" wta crc drc conf changed line loc path n_in=0 n_pre=0 n_gate=0 rpo prc budget
  # Until the pack step judges, it has not: an early return 2 is could-not-run.
  PREPR_SCAN_PACK=could-not-run
  PREPR_SCAN_CILOCAL=could-not-run
  mkdir -p "$out" || return 2
  : > "$out/prepr-findings.txt"; : > "$out/prepr-preexisting.txt"
  if [ ! -x "$wt/bin/checks-run.sh" ] || [ ! -x "$wt/bin/test-determinism-lint.sh" ]; then
    echo "prepr: skipped (repo ships no pre-PR gates)" > "$out/prepr-scan.txt"
    PREPR_SCAN_PACK=skipped
    PREPR_SCAN_CILOCAL=skipped
    return 3
  fi
  wta=$(cd "$wt" && pwd) || return 2
  # The repo's own conf, as CI reads it: CI has no flags/ override.
  conf=""; [ -r "$wta/catalog/determinism-lint.conf" ] && conf="$wta/catalog/determinism-lint.conf"
  ( cd "$wta" && env -u CHECKS_DIR timeout 300 bin/checks-run.sh --tree . ) > "$out/checks.txt" 2>&1; crc=$?
  ( cd "$wta" && DETERMINISM_LINT_CONF="$conf" timeout 300 bin/test-determinism-lint.sh ) > "$out/determinism.txt" 2>&1; drc=$?
  printf 'checks-run rc=%s\ndeterminism-lint rc=%s\n' "$crc" "$drc" > "$out/prepr-scan.txt"
  if [ "$crc" -ge 2 ] || [ "$drc" -ge 2 ]; then
    echo "prepr: could not run (a gate exited >= 2 or timed out)" >> "$out/prepr-scan.txt"
    return 2
  fi
  if ! changed=$(git -C "$wta" diff --name-only "$base"...HEAD 2>>"$out/prepr-scan.txt"); then
    echo "prepr: could not run (no diff against $base)" >> "$out/prepr-scan.txt"
    return 2
  fi
  _prepr_orphans "$wta" "$base" "$out" || return 2
  # The rules pack (BH-3513). It judges the diff itself, so every line it prints
  # is this build's; a pack that could not run is noted and changes nothing.
  : > "$out/rules-pack-findings.txt"
  if [ ! -x "$wta/bin/rules-pack.sh" ]; then
    echo "rules-pack: skipped" >> "$out/prepr-scan.txt"
    PREPR_SCAN_PACK=skipped
  else
    # A fresh --out each scan: the re-scan must never read the first one's files.
    rpo="$(cd "$out" && pwd)/rules-pack"
    rm -rf -- "${rpo:?}"
    budget=$(rules_pack_budget)
    ( cd "$wta" && timeout $((3 * budget)) bin/rules-pack.sh --tree . --base "$base" --skip checks-tree,determinism --out "$rpo" ) \
      > "$out/rules-pack-findings.txt" 2> "$out/rules-pack.err"; prc=$?
    echo "rules-pack rc=$prc" >> "$out/prepr-scan.txt"
    if [ "$prc" = 0 ]; then
      PREPR_SCAN_PACK=clean
    elif [ "$prc" = 1 ] && [ -s "$out/rules-pack-findings.txt" ]; then
      PREPR_SCAN_PACK=red
    else
      echo "rules-pack: could not run (rc $prc): $(tail -3 "$out/rules-pack.err" 2>/dev/null | tr '\n' ' ')" >> "$out/prepr-scan.txt"
      PREPR_SCAN_PACK=could-not-run
      : > "$out/rules-pack-findings.txt"
    fi
    if { [ "$prc" = 0 ] || [ "$prc" = 1 ]; } && [ -s "$rpo/preexisting.txt" ]; then
      while IFS= read -r line; do
        [ -n "$line" ] || continue
        printf 'RULES-PACK %s\n' "$line" >> "$out/prepr-preexisting.txt"; n_pre=$((n_pre + 1))
      done < "$rpo/preexisting.txt"
    fi
  fi
  # >>> ci-local (BH-6897)
  # CI's lint job, from the tree's own workflow. The pack already ran above.
  : > "$out/ci-local-findings.txt"
  if command -v cl_run >/dev/null 2>&1; then
    PREPR_SCAN_CILOCAL=$(cl_run "$wta/bin/ci-local.sh" "$wta" "$base" "$out/ci-local" --skip-rules-pack)
  else
    PREPR_SCAN_CILOCAL=off
  fi
  echo "ci-local: ${PREPR_SCAN_CILOCAL:-could-not-run}" >> "$out/prepr-scan.txt"
  case "$PREPR_SCAN_CILOCAL" in
    red) grep '^CI-LOCAL ' "$out/ci-local/findings.txt" > "$out/ci-local-findings.txt" ;;
    could-not-run) echo "ci-local: could not run: $(tail -n 1 "$out/ci-local.stdout" 2>/dev/null)" >> "$out/prepr-scan.txt" ;;
  esac
  if [ -s "$out/ci-local/preexisting.txt" ]; then
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      printf '%s\n' "$line" >> "$out/prepr-preexisting.txt"; n_pre=$((n_pre + 1))
    done < "$out/ci-local/preexisting.txt"
  fi
  # <<< ci-local
  # CHECK-HIT <slug> <path>:<line> <reason>, and the determinism lint's FAIL
  # section only (<path>:<n>: <rule>: ...), never its warnings.
  {
    grep '^CHECK-HIT ' "$out/checks.txt"
    awk '/^── determinism findings \(fail\)/{f=1;next} /^──/{f=0} f && /^[^[:space:]][^:]*:[0-9]+: [^:]+:/' "$out/determinism.txt"
    cat "$out/orphans-findings.txt" 2>/dev/null
    [ "$PREPR_SCAN_PACK" = red ] && sed 's/^/RULES-PACK /' "$out/rules-pack-findings.txt"
    cat "$out/ci-local-findings.txt"
  } > "$out/prepr-all.txt"
  while IFS= read -r line; do
    case "$line" in
      "CHECK-HIT "*) loc=$(awk '{print $3}' <<<"$line") ;;
      "RULES-PACK "*|"CI-LOCAL "*) loc="" ;;
      *) loc="$line" ;;
    esac
    case "$line" in "RULES-PACK "*|"CI-LOCAL "*) ;; *) n_gate=$((n_gate + 1)) ;; esac
    path=$(_prepr_path "$wta" "${loc%%:*}")
    # An ORPHAN is new against the base by construction, so it is this build's
    # even when the file it names is not in the diff (a suite edit can orphan
    # an untouched script). A RULES-PACK line is too: the pack judged the diff.
    # So is a CI-LOCAL line: ci-local set aside every step red on the base.
    if [ "${line#ORPHAN }" != "$line" ] || [ "${line#RULES-PACK }" != "$line" ] \
       || [ "${line#CI-LOCAL }" != "$line" ] || grep -qxF -- "$path" <<<"$changed"; then
      printf '%s\n' "$line" >> "$out/prepr-findings.txt"; n_in=$((n_in + 1))
    else
      printf '%s\n' "$line" >> "$out/prepr-preexisting.txt"; n_pre=$((n_pre + 1))
    fi
  done < "$out/prepr-all.txt"
  # A gate that said "found something" but left nothing this parser can read
  # is a parse that failed, not a clean tree. Pack and ci-local lines do not
  # count here: they must not hide a determinism lint nobody could parse.
  if { [ "$crc" = 1 ] || [ "$drc" = 1 ]; } && [ "$n_gate" -eq 0 ]; then
    echo "prepr: could not run (a gate reported findings this scan could not parse)" >> "$out/prepr-scan.txt"
    return 2
  fi
  printf 'in-diff=%s preexisting=%s\n' "$n_in" "$n_pre" >> "$out/prepr-scan.txt"
  [ "$n_in" -gt 0 ] && return 1
  return 0
}

# _prepr_knob <ENV> — `lane_knob fly-pool <ENV> "$PROJECT"`, or nothing when
# nothing answers. Resolved in a subshell so lane-gate.sh's globals never land
# in the driver.
_prepr_knob() {
  local lg v="" self
  self="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  for lg in "${HARNESS:-/root/harness}/bin/lib/lane-gate.sh" "$self/lane-gate.sh"; do
    [ -r "$lg" ] || continue
    v=$( . "$lg" 2>/dev/null && lane_knob fly-pool "$1" "${PROJECT:-}" 2>/dev/null )
    break
  done
  printf '%s' "$v"
}

# rules_pack_budget — the resolved RULES_PACK_BUDGET_S when it is a whole
# number >= 1, else the registry default 60.
rules_pack_budget() {
  local v
  v=$(_prepr_knob RULES_PACK_BUDGET_S)
  case "$v" in ''|*[!0-9]*|0) v=60 ;; esac
  printf '%s' "$v"
}

# _prepr_turns — the resolved RB_PREPR_FIX_TURNS, clamped to 0..1, or empty
# when nothing answers.
_prepr_turns() {
  local v
  v=$(_prepr_knob RB_PREPR_FIX_TURNS)
  case "${v:-}" in ''|*[!0-9]*) return 0 ;; esac
  [ "$v" -gt 1 ] && v=1
  printf '%s' "$v"
}

prepr_gate() {
  local wt="$1" base="$2" build="$3" turns
  PREPR_STATE=""; PREPR_NOTE=""; PREPR_SECTION=""
  mkdir -p "$build" || return 0
  turns=$(_prepr_turns)
  if [ -z "$turns" ]; then
    _prepr_log "$build" "PREPR RB_PREPR_FIX_TURNS did not resolve (registry unreadable?) — detection only, no fix turn"
    turns=0
  fi
  _prepr_run "$wt" "$base" "$build" "$build" "$turns" "" 0
  return 0
}

# prepr_gate_late <wt> <base> <build> — BH-2021. The first pass runs right after
# execute; the review fix rounds and the pre-PR rebase onto origin/<base> can
# still move the head after it (#1983: a raw rm from a review fix round, a
# sigpipe-negative hit from main's newer lint on the rebase). This re-runs the
# same gate on the head the PR opens with, artifacts under <build>/prepr-late/.
# The head the first pass judged (<build>/prepr-head) is skipped as
# `unchanged`. The fix turn is the build's, not the pass's: the knob minus the
# fix_calls= the first pass recorded, so a spent turn plus in-diff findings is
# `red` with a section (never the silent `off`). A late verdict from a scan that
# ran replaces PREPR_STATE/NOTE/SECTION; `could-not-run` keeps the first pass's.
prepr_gate_late() {
  local wt="$1" base="$2" build="$3" out="$3/prepr-late" head knob spent turns spent_flag=0
  local s0="${PREPR_STATE:-}" n0="${PREPR_NOTE:-}" x0="${PREPR_SECTION:-}"
  local p0="${PREPR_PACK_STATE:-}" o0="${PREPR_PACK_OUT:-}" l0="${PREPR_LINT_STATE:-}" lo0="${PREPR_LINT_OUT:-}"
  mkdir -p "$out" || return 0
  head=$(git -C "$wt" rev-parse HEAD 2>/dev/null)
  if [ -n "$head" ] && [ -f "$build/prepr-head" ] && [ "$(cat "$build/prepr-head")" = "$head" ]; then
    printf 'state=unchanged\nhead=%s\n' "$head" > "$out/prepr.txt"
    _prepr_log "$build" "PREPR late state=unchanged head=${head:0:12}"
    return 0
  fi
  # After the pre-PR rebase a stale local <base> would list main's own files
  # as this build's (the scope gate resolves the same way).
  git -C "$wt" rev-parse -q --verify "origin/$base" >/dev/null 2>&1 && base="origin/$base"
  knob=$(_prepr_turns)
  if [ -z "$knob" ]; then
    _prepr_log "$build" "PREPR late RB_PREPR_FIX_TURNS did not resolve (registry unreadable?) — detection only, no fix turn"
    knob=0
  fi
  spent=$(sed -n 's/^fix_calls=//p' "$build/prepr.txt" 2>/dev/null | head -1)
  case "$spent" in ''|*[!0-9]*) spent=0 ;; esac
  turns=$((knob - spent)); [ "$turns" -lt 0 ] && turns=0
  [ "$knob" -gt 0 ] && [ "$turns" -eq 0 ] && spent_flag=1
  _prepr_run "$wt" "$base" "$build" "$out" "$turns" "late " "$spent_flag"
  if [ "$PREPR_STATE" = could-not-run ]; then
    PREPR_STATE="$s0"; PREPR_NOTE="$n0"; PREPR_SECTION="$x0"; PREPR_LINT_STATE="$l0"; PREPR_LINT_OUT="$lo0"
    _prepr_log "$build" "PREPR late could not run — the PR keeps the first pass's verdict (${s0:-none})"
  fi
  # A late pack that could not judge keeps the first pass's pack verdict.
  if [ "$PREPR_STATE" = could-not-run ] || [ "$PREPR_PACK_STATE" = could-not-run ]; then
    PREPR_PACK_STATE="$p0"; PREPR_PACK_OUT="$o0"
  fi
  return 0
}

# _prepr_run <wt> <base> <build> <out> <turns> <label> <spent> — one gate pass:
# scan into <out>, at most <turns> (0..1) fix turn(s), re-scan. <spent>=1 means
# the knob allowed a turn the build already used, so in-diff findings are red,
# not off. Sets PREPR_STATE/NOTE/SECTION, writes <out>/prepr.txt, logs
# `PREPR <label>state=`, and records the judged head in <build>/prepr-head.
_prepr_run() {
  local wt="$1" base="$2" build="$3" out="$4" turns="$5" label="$6" spent="$7" rc pre dirty rules n n_pre tools reasons="" calls=0 ccrc
  local pack_first_red=0 pack_rules="" pack_why="" srcs cl_first_red=0 cl_rules="" cl_why=""
  PREPR_STATE=""; PREPR_NOTE=""; PREPR_SECTION=""; PREPR_PACK_STATE=""; PREPR_PACK_OUT="$out"
  prepr_scan "$wt" "$base" "$out"; rc=$?
  cp "$out/prepr-findings.txt" "$out/prepr-findings.first.txt" 2>/dev/null
  grep -q '^RULES-PACK ' "$out/prepr-findings.txt" 2>/dev/null && pack_first_red=1
  grep -q '^CI-LOCAL ' "$out/prepr-findings.txt" 2>/dev/null && cl_first_red=1
  case "$rc" in
    0) PREPR_STATE=clean ;;
    2) PREPR_STATE=could-not-run ;;
    3) PREPR_STATE=skipped ;;
    *) if [ "$turns" -eq 0 ]; then
         if [ "$spent" = 1 ]; then
           PREPR_STATE=red
           reasons="- The build already spent its pre-PR fix turn on the first pass.
"
         else
           PREPR_STATE=off
         fi
       fi ;;
  esac
  if [ -z "$PREPR_STATE" ]; then
    pre=$(git -C "$wt" rev-parse HEAD 2>/dev/null)
    local brief pack_bullet=""
    srcs="\`bin/checks-run.sh --tree .\`, \`bin/test-determinism-lint.sh\` and \`bin/test-impact.sh orphans --check\`"
    if [ "$pack_first_red" = 1 ]; then
      srcs="\`bin/checks-run.sh --tree .\`, \`bin/test-determinism-lint.sh\`, \`bin/test-impact.sh orphans --check\` and \`bin/rules-pack.sh\`"
      pack_bullet="
- A \`RULES-PACK <id>: …\` line is a repo ratchet from \`bin/rules-pack.sh\` (run it with \`--only <id>\` to reproduce). Fix the code it names. Never edit a ratchet's baseline or the pack itself."
    fi
    if [ "$cl_first_red" = 1 ]; then
      srcs="${srcs% and *}, ${srcs##* and } and \`bin/ci-local.sh\`"
      pack_bullet="${pack_bullet}
- A \`CI-LOCAL <job> / <step>: …\` line is a step of the CI lint job, run by \`bin/ci-local.sh --step '<step>'\` (its log is step-<n>.log under the build record's ci-local/). Fix the code it names. Never edit the workflow, \`bin/ci-local.sh\`, \`bin/ci-local-plan.py\` or \`catalog/ci-local-skip.d/\`."
    fi
    brief="The pre-PR gate found the problems below in files this build changed. They are the output of ${srcs}, the same commands cromford CI runs, and CI will fail this PR on them.

Fix each one in the code on branch ${BRANCH:-the current branch}, then commit. Do not push.
- Never weaken, skip or delete a test to make a finding go away.
- Never edit checks/, guardrails/, catalog/determinism-lint.conf or bin/test-impact.sh.
- A \`# determinism: ok <reason>\` waiver is only for a line that really is deterministic, and it needs the true reason.
- An ORPHAN line is a new source file that no tests/*.sh suite names. Every new source file, console-ui included, must be named by rooted path on a non-comment line (\"\$DIR/console-ui/src/lib/x.js\") in a tests/*.sh suite; a path that appears only in a # comment does not count, and neither does a node test that imports it by a relative path. Add or extend a shell suite the way tests/cost-breaker-console.bh-2331-test.sh does.${pack_bullet}
- Leave nothing uncommitted: the PR carries only what is committed.

Findings:
$(cat "$out/prepr-findings.txt")"
    CC fix "$FIX_MODEL" 4800 "$out/prepr-fix-run.txt" "$brief"; ccrc=$?
    calls=1
    [ "$ccrc" = 0 ] || _prepr_log "$build" "PREPR ${label}fix turn exited $ccrc — the re-scan decides"
    dirty=$(git -C "$wt" status --porcelain --untracked-files=no 2>/dev/null)
    rules=$(git -C "$wt" diff --name-only "$pre"..HEAD 2>/dev/null | grep -E '^(checks/|guardrails/|catalog/determinism-lint\.conf$|bin/test-impact\.sh$)|^(bin/rules-pack\.sh|bin/lib/rules-pack-[a-z-]+\.sh|catalog/rules-pack\.tsv|catalog/date-bomb-lint\.conf|bin/test-date-bomb-lint\.sh|tests/alert-writers-ratchet-baseline/|tests/switch-ratchet\.d/|tests/fixtures/root-fallback-baseline/)')
    cl_rules=$(grep -E "$_PREPR_CL_RULES" <<<"$(git -C "$wt" diff --name-only "$pre"..HEAD 2>/dev/null)")
    [ -n "$cl_rules" ] && rules="${rules:+$rules
}$cl_rules"
    pack_rules=$(grep -E '^(bin/rules-pack\.sh|bin/lib/rules-pack-[a-z-]+\.sh|catalog/rules-pack\.tsv|catalog/date-bomb-lint\.conf|bin/test-date-bomb-lint\.sh|tests/alert-writers-ratchet-baseline/|tests/switch-ratchet\.d/|tests/fixtures/root-fallback-baseline/)' <<<"$rules")
    prepr_scan "$wt" "$base" "$out"; rc=$?
    [ -n "$dirty" ] && reasons="${reasons}- The fix turn left uncommitted changes, which are not in this PR.
"
    [ -n "$rules" ] && reasons="${reasons}- The fix turn edited the gate's own rules: $(tr '\n' ' ' <<<"$rules")
"
    [ "$rc" = 2 ] && reasons="${reasons}- The re-scan after the fix turn could not run (see prepr-scan.txt in the build record).
"
    if [ "$rc" = 0 ] && [ -z "$reasons" ]; then PREPR_STATE=fixed; else PREPR_STATE=red; fi
  fi
  n=$(grep -c . "$out/prepr-findings.txt" 2>/dev/null); n=${n:-0}
  n_pre=$(grep -c . "$out/prepr-preexisting.txt" 2>/dev/null); n_pre=${n_pre:-0}
  if [ "$PREPR_STATE" = red ]; then
    PREPR_NOTE=" | prepr=red"
    tools=""
    grep -q '^CHECK-HIT ' "$out/prepr-findings.txt" 2>/dev/null && tools="\`bin/checks-run.sh --tree .\`"
    grep -Ev '^(CHECK-HIT|ORPHAN|RULES-PACK|CI-LOCAL) ' "$out/prepr-findings.txt" 2>/dev/null | grep -q . && tools="${tools:+$tools and }\`bin/test-determinism-lint.sh\`"
    grep -q '^ORPHAN ' "$out/prepr-findings.txt" 2>/dev/null && tools="${tools:+$tools and }\`bin/test-impact.sh orphans --check\`"
    grep -q '^RULES-PACK ' "$out/prepr-findings.txt" 2>/dev/null && tools="${tools:+$tools and }\`bin/rules-pack.sh\`"
    grep -q '^CI-LOCAL ' "$out/prepr-findings.txt" 2>/dev/null && tools="${tools:+$tools and }\`bin/ci-local.sh\`"
    PREPR_SECTION=$'\n## Pre-PR gate: unresolved\n\n'
    if [ "$n" -gt 0 ]; then
      if [ "$calls" = 1 ]; then
        PREPR_SECTION+="${tools} still report ${n} finding(s) in files this PR changes, after one fix turn. CI runs the same commands and will fail on them."
      else
        PREPR_SECTION+="${tools} report ${n} finding(s) in files this PR changes, on the head this PR opens with. CI runs the same commands and will fail on them."
      fi
      PREPR_SECTION+=$'\n\n```\n'"$(head -40 "$out/prepr-findings.txt")"$'\n```\n'
      [ "$n" -gt 40 ] && PREPR_SECTION+="Showing 40 of ${n}; the full list is prepr-findings.txt in the build record."$'\n'
    else
      PREPR_SECTION+="The gates found nothing left in this PR's files, but the fix turn did not end clean:"$'\n'
    fi
    [ -n "$reasons" ] && PREPR_SECTION+=$'\n'"$reasons"
  fi
  # The pack's own verdict, decided on the final scan. A pack that was red and
  # went green only because the fix turn edited its rules, or that could not
  # re-run after the turn, is still red: an unverified fix is not a fix.
  if grep -q '^RULES-PACK ' "$out/prepr-findings.txt" 2>/dev/null; then
    PREPR_PACK_STATE=red
    grep '^RULES-PACK ' "$out/prepr-findings.txt" > "$out/rules-pack-remaining.txt"
  elif [ "$pack_first_red" = 1 ] && [ -n "$pack_rules" ]; then
    pack_why="the fix turn edited the pack's own rules: $(tr '\n' ' ' <<<"$pack_rules")"
  elif [ "$pack_first_red" = 1 ] && [ "${PREPR_SCAN_PACK:-}" = could-not-run ]; then
    pack_why="the pack could not re-run after the fix turn"
  else
    case "${PREPR_SCAN_PACK:-}" in
      could-not-run|skipped) PREPR_PACK_STATE="$PREPR_SCAN_PACK" ;;
      *) PREPR_PACK_STATE=clean ;;
    esac
  fi
  if [ -n "$pack_why" ]; then
    PREPR_PACK_STATE=red
    { grep '^RULES-PACK ' "$out/prepr-findings.first.txt"; echo "(still red: $pack_why)"; } > "$out/rules-pack-remaining.txt"
  fi
  # THE FAST LINTS BLOCK TOO (BH-5797). A determinism-lint or ORPHAN line still
  # in this diff after the fix turn is a fix, not a PR: rules_pack_block stops
  # it the way it stops a red pack. A CHECK-HIT keeps the unresolved section.
  PREPR_LINT_STATE=clean
  # Only after a fix turn: PREPR_STATE=off (the fix-turn knob at 0, no turn) is
  # detection only, as the knob documents (lead review lr-5811).
  PREPR_LINT_OUT="$out"
  # A CI-LOCAL line counts here too (BH-6897), and so does a ci-local that was
  # red and went green only through an edit to its own rules, or could not
  # re-run after the turn: an unverified fix is not a fix.
  if [ "$cl_first_red" = 1 ] && ! grep -q '^CI-LOCAL ' "$out/prepr-findings.txt" 2>/dev/null; then
    if [ -n "$cl_rules" ]; then cl_why="the fix turn edited ci-local's own rules: $(tr '\n' ' ' <<<"$cl_rules")"
    elif [ "${PREPR_SCAN_CILOCAL:-}" != clean ]; then cl_why="ci-local could not re-run after the fix turn (${PREPR_SCAN_CILOCAL:-none})"; fi
  fi
  # cl_why does not depend on PREPR_STATE: a ci-local that could not re-run
  # leaves prepr_scan at rc 0 (PREPR_STATE=fixed), and the head is still
  # unchecked. Same as the pack's pack_why above (lead review lr-7005).
  if { [ "$PREPR_STATE" = red ] && grep -Ev '^(CHECK-HIT|RULES-PACK) ' "$out/prepr-findings.txt" 2>/dev/null | grep -q .; } || [ -n "$cl_why" ]; then
    PREPR_LINT_STATE=red
    grep -Ev '^(CHECK-HIT|RULES-PACK) ' "$out/prepr-findings.txt" > "$out/fast-lints-remaining.txt" 2>/dev/null
    [ -n "$cl_why" ] && { grep '^CI-LOCAL ' "$out/prepr-findings.first.txt"; echo "(still red: $cl_why)"; } >> "$out/fast-lints-remaining.txt"
    _prepr_log "$build" "PREPR ${label}fast lints red: $(grep -c . "$out/fast-lints-remaining.txt") determinism, orphan or ci-local finding(s) in this diff"
  fi
  printf 'state=%s\nfindings=%s\npreexisting=%s\nturns=%s\nfix_calls=%s\npack=%s\ncilocal=%s\n' \
    "$PREPR_STATE" "$n" "$n_pre" "$turns" "$calls" "$PREPR_PACK_STATE" "${PREPR_SCAN_CILOCAL:-could-not-run}" > "$out/prepr.txt"
  _prepr_log "$build" "PREPR ${label}state=$PREPR_STATE findings=$n preexisting=$n_pre turns=$turns fix_calls=$calls pack=$PREPR_PACK_STATE"
  _prepr_log "$build" "PREPR ${label}ci-local=${PREPR_SCAN_CILOCAL:-could-not-run} red=$(grep -c '^CI-LOCAL ' "$out/prepr-findings.txt" 2>/dev/null)"
  # A scan that could not run judged nothing, so it records no head: the late
  # pass must not read it as already covered.
  [ "$PREPR_STATE" = could-not-run ] || git -C "$wt" rev-parse HEAD > "$build/prepr-head" 2>/dev/null
  return 0
}

# rules_pack_block <where> — BH-3513. Stop a build whose rules pack is still red
# after the fix turn (PREPR_PACK_STATE=red), unless RULES_PACK_BLOCK is 0. Uses
# the driver's RESULT and escalate_block; only called where both exist.
rules_pack_block() {
  local where="$1" k n f what=""
  [ "${PREPR_PACK_STATE:-}" = red ] || [ "${PREPR_LINT_STATE:-}" = red ] || return 0
  k=$(_prepr_knob RULES_PACK_BLOCK)
  if [ "$k" = 0 ]; then
    if [ "${PREPR_PACK_STATE:-}" = red ]; then
      _prepr_log "$BUILD" "PREPR rules pack red — RULES_PACK_BLOCK=0, the PR opens with the unresolved section"
    else
      _prepr_log "$BUILD" "PREPR fast lints red — RULES_PACK_BLOCK=0, the PR opens with the unresolved section"
    fi
    return 0
  fi
  f="$BUILD/rules-pack-remaining.all"
  : > "$f"
  if [ "${PREPR_PACK_STATE:-}" = red ]; then
    cat "${PREPR_PACK_OUT:-$BUILD}/rules-pack-remaining.txt" >> "$f" 2>/dev/null; what="the rules pack"
  fi
  if [ "${PREPR_LINT_STATE:-}" = red ]; then
    cat "${PREPR_LINT_OUT:-$BUILD}/fast-lints-remaining.txt" >> "$f" 2>/dev/null; what="${what:+$what and }the fast lints"
  fi
  # Findings only: the pack's "(still red: <why>)" note is not one.
  n=$(grep -cv '^(still red: ' "$f" 2>/dev/null); n=${n:-0}
  { head -40 "$f" 2>/dev/null
    [ "$(grep -c . "$f" 2>/dev/null)" -gt 40 ] && echo "Showing 40 of $(grep -c . "$f")"
  } > "$BUILD/rules-pack-block.txt"
  [ "$what" = "the rules pack" ] && what="the rules pack is" || what="$what are"
  [ -x "$HARNESS/bin/alert-line.sh" ] && "$HARNESS/bin/alert-line.sh" --project "$PROJECT" \
    "[$PROJECT/$KEY] BLOCKED: $what red on this build's own diff after the pre-PR fix turn (rules-pack) ($where)"
  escalate_block "rules-pack" "$n repo ratchet or fast-lint finding(s) in this diff are still red after the fix turn: $(head -5 "$f" 2>/dev/null | tr '\n' ';')"
  RESULT "REVIEW_BLOCKED rules-pack: $n finding(s) still red after the pre-PR fix turn; see $BUILD/rules-pack-block.txt"
  exit 6
}

# _prepr_parents — the N of every `Part of #N` line (bin/decompose-parent-close.sh
# part_re: markdown decoration, any case, optional colon) in the ticket body
# and the plan, and every `SLICE: C<k> of #N` plan line (BH-4662). Nothing, and
# rc 1, when there is no ticket-meta.json.
#   The SLICE line is matched in the shape issue_close_guard matches it at merge
#   (bin/lib/issue-state-lib.sh): at line start, markdown `*`, `_`, `>` allowed,
#   all of N's digits. A table row, a mid-line quote and prose are not it. The
#   older sentence form ("The build for THIS ticket is C<k>") names no issue, so
#   it rewrites nothing here; the guard still answers slice:plan for it.
_prepr_parents() {
  local b="${BUILD:-}"
  [ -n "$b" ] && [ -f "$b/ticket-meta.json" ] || return 1
  # The plan is optional; its absence must not become this pipe's status under
  # pipefail, or a child with no plan.md would read as "no ticket-meta".
  { { jq -r '.body // ""' "$b/ticket-meta.json" 2>/dev/null; if [ -f "$b/plan.md" ]; then cat "$b/plan.md"; fi; } \
      | sed -nE 's/^[[:space:]>*_#-]*[Pp][Aa][Rr][Tt][- ][Oo][Ff]([^A-Za-z0-9_#][^#]*)?#([0-9]+).*/\2/p'
    if [ -f "$b/plan.md" ]; then
      sed -nE 's/^[[:space:]*_>]*SLICE:[[:space:]*_]*C[0-9]+[[:space:]]+of[[:space:]]+#([0-9]+)([^0-9].*)?$/\1/p' "$b/plan.md"
    fi; } \
    | sort -u
  return 0
}

prepr_body_keywords() {
  local parents p expr=()
  parents=$(_prepr_parents) || { cat; return 0; }
  for p in $parents; do
    expr+=(-e "s/(^|[^A-Za-z0-9_])(close[sd]?|fix(e[sd])?|resolve[sd]?):?[[:space:]]+#${p}([^0-9]|\$)/\\1Part of #${p}\\4/Ig")
  done
  [ "${#expr[@]}" -gt 0 ] || { cat; return 0; }
  sed -E "${expr[@]}"
}
