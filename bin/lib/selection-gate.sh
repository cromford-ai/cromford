#!/bin/bash
# bin/lib/selection-gate.sh — the builder's pre-PR selection gate (BH-8062,
# shape B). Sourced by bin/lib/rb/pr.sh after the prepush gate and before the
# push, never executed.
#
# sg_block runs bin/selection-gate.sh (the merge-queue batch's selection for
# this head, on the fleet test host) in the checkout, copies its gate.txt to
# $BUILD/gate.txt and logs one `SELECTION-GATE rc=<rc> suites=<n> red=<list>`
# line. Then:
#   green, could-not-run, no-selection  SG_MARKER is set to the record the lead
#       review reads, `<!-- selection-gate: head=<40-hex> suites=<n> rc=<rc> -->`,
#       and it returns 0: the build goes on to the push. could-not-run and
#       no-selection are never green: the marker says which, and the batch
#       stays the backstop.
#   red  sg_notice posts one board comment that names the red suites, RESULT
#       is `GATE_RED <n> red: <suites>; see <build>/gate.txt`, and it returns 6.
#       The caller exits 6: nothing is pushed and no PR opens.
# A checkout with no executable bin/selection-gate.sh (every other project) is
# not gated: one log line, rc 0, no marker. The knob SELECTION_GATE at 0 (in a
# checkout that has the gate): the gate does not run; sg_off_gate writes an
# rc=off gate.txt, SG_MARKER carries the rc=off record, which the lead review
# accepts, and it returns 0 with no alert.
#
# KNOBS (fly-pool lane, `lane_knob fly-pool <ENV> "$PROJECT"`, else the env,
# else the fallback named on each read): SELECTION_GATE, SELECTION_GATE_TIMEOUT_S,
# SELECTION_GATE_P, SELECTION_GATE_FIX_TIMEOUT_S (the bound on that fix turn), SELECTION_GATE_FIX_ROUNDS (0 = a red ends the build; 1 = one
# fix turn through CC, then the gate runs again), SELECTION_GATE_CNR_ALERT and
# SELECTION_GATE_CNR_KEEP_DAYS (sg_cnr_alert, r3 F4).
#
# The caller provides STAMP, RESULT, PROJECT, KEY, BUILD, BASE and, for the
# notice, TICKET, BUILDER_DIRECT_ON and HARNESS. The root is ${HARNESS:-${H:-}}
# only (D43): with none, the knobs fall back and no notice is posted.

# _sg_knob <ENV> <fallback> — the fly-pool lane knob, else the env of that
# name, a whole number, else the fallback. Resolved in a subshell so
# lane-gate.sh's globals stay out.
_sg_knob() {
  local root="${HARNESS:-${H:-}}" v=""
  if [ -n "$root" ] && [ -r "$root/bin/lib/lane-gate.sh" ]; then
    v=$( . "$root/bin/lib/lane-gate.sh" 2>/dev/null && lane_knob fly-pool "$1" "${PROJECT:-}" 2>/dev/null )
  fi
  [ -n "$v" ] || v="${!1:-}"
  case "$v" in ''|*[!0-9]*) v=$2 ;; esac
  printf '%s' "$v"
}

_sg_log() { echo "$(STAMP) [${PROJECT:-}/${KEY:-}] $1" >> "$BUILD/pipeline.log"; }

# _sg_field <gate.txt> <name> — one field of gate.txt.
_sg_field() { sed -n "s/^$2: //p" "$1" 2>/dev/null | head -n 1; }

# sg_marker <gate.txt> — the PR-body record for a non-red gate.txt, or nothing
#   when its head or count is unreadable (the lead review then reads "missing").
sg_marker() {
  local g="${1:-}" h n r
  h=$(_sg_field "$g" head); n=$(_sg_field "$g" suites); r=$(_sg_field "$g" rc)
  [[ "$h" =~ ^[0-9a-f]{40}$ ]] && [[ "$n" =~ ^[0-9]+$ ]] || return 1
  case "$r" in 0|could-not-run|no-selection|off) ;; *) return 1 ;; esac
  printf '<!-- selection-gate: head=%s suites=%s rc=%s -->' "$h" "$n" "$r"
}

# sg_marker_replace <body> <marker> — PURE. The PR body with its selection-gate
#   record set to <marker> (r3, F3: a resolver fix round pushed a new head):
#   the first `<!-- selection-gate: … -->` becomes <marker>, every later one is
#   dropped (a line left empty by a drop is dropped with it), and a body with
#   none gets <marker> appended on its own line. Every other byte is kept, a
#   trailing \r included. stdout: the new body, no trailing newline added.
sg_marker_replace() {
  local body="${1:-}" mk="${2:-}" re='^(.*)<!--[[:space:]]*selection-gate:[^>]*>(.*)$' ph=$'\001' out=() lines=() l had seen=0 first=1 res=""
  mapfile -t lines <<<"$body"
  for l in "${lines[@]}"; do
    had=0
    while [[ "$l" =~ $re ]]; do l="${BASH_REMATCH[1]}$ph${BASH_REMATCH[2]}"; had=1; done
    if [ "$had" = 1 ]; then
      if [ "$seen" = 0 ]; then l="${l/$ph/$mk}"; seen=1; fi
      l="${l//$ph/}"
      [ "$l" = "" ] || [ "$l" = $'\r' ] && continue
    fi
    out+=("$l")
  done
  for l in "${out[@]}"; do
    if [ "$first" = 1 ]; then res="$l"; first=0; else res+=$'\n'"$l"; fi
  done
  if [ "$seen" = 0 ]; then
    if [ -n "$body" ]; then res+=$'\n'"$mk"; else res="$mk"; fi
  fi
  printf '%s' "$res"
}

# sg_cnr_alert <gate.txt> — F4 (r3). A could-not-run gate.txt, with the knob
#   SELECTION_GATE_CNR_ALERT at 1, writes ONE ALERTS.log line per box per UTC
#   day: the pool image has no test-host route, and a build that cannot reach
#   the host must not be silent. The day marker is
#   $root/state/selection-gate/cnr-<yyyymmdd>, made with mkdir (atomic, so two
#   builds on one box race to one line). Markers older than
#   SELECTION_GATE_CNR_KEEP_DAYS (default 14) days are deleted on the same call. Through bin/alert-line.sh only (no alert-line.sh:
#   one pipeline.log line, and no marker, so a later build tries again). rc 0
#   always (fail-open).
sg_cnr_alert() {
  local g="${1:-}" root="${HARNESS:-${H:-}}" why day dir host msg keep
  [ -n "$root" ] || return 0
  [ "$(_sg_field "$g" rc)" = could-not-run ] || return 0
  [ "$(_sg_knob SELECTION_GATE_CNR_ALERT 1)" = 1 ] || return 0   # lane.fly-pool.selection_gate_cnr_alert
  dir="$root/state/selection-gate"; mkdir -p "$dir" 2>/dev/null || return 0
  keep=$(_sg_knob SELECTION_GATE_CNR_KEEP_DAYS 14)   # lane.fly-pool.selection_gate_cnr_keep_days
  find "$dir" -maxdepth 1 -name 'cnr-*' -mtime "+$keep" -exec rm -rf {} + 2>/dev/null
  day=$(date -u +%Y%m%d)
  mkdir "$dir/cnr-$day" 2>/dev/null || return 0
  why=$(_sg_field "$g" why); host=$(hostname 2>/dev/null || echo unknown-host)
  msg="SELECTION GATE COULD NOT RUN on $host: ${why:-unknown}. Builds open PRs with no pre-PR selection run; the batch is the only check. Needed: a test-host route on the builder image (flyctl + test-host cert), from an operator."
  if [ -x "$root/bin/alert-line.sh" ]; then
    HARNESS="$root" "$root/bin/alert-line.sh" --id "selection-gate-cnr-$host-$day" "$msg" >/dev/null 2>&1
    _sg_log "SELECTION-GATE could-not-run alert written ($why)"
  else
    rmdir "$dir/cnr-$day" 2>/dev/null
    _sg_log "SELECTION-GATE could-not-run, and no bin/alert-line.sh to say so"
  fi
  return 0
}

# sg_off_gate <tree> <outdir> — the gate.txt of a gate the knob turned off, in
#   the 9-field format of bin/selection-gate.sh write_gate (rc `off`), through
#   a temp file and one rename. rc 1, and no file, when <tree> has no HEAD.
sg_off_gate() {
  local tree="${1:-.}" od="${2:-}" h t
  h=$(git -C "$tree" rev-parse HEAD 2>/dev/null) || h=""
  [[ "$h" =~ ^[0-9a-f]{40}$ ]] && [ -n "$od" ] || return 1
  mkdir -p "$od" 2>/dev/null || return 1
  t="$od/gate.txt.tmp.$$"
  printf 'head: %s\nbase: -\nsuites: 0\nrc: off\nred: -\nnoted: -\nmode: -\nwhy: SELECTION_GATE=0\nquarantine: -\n' "$h" > "$t" \
    && mv -f "$t" "$od/gate.txt" || { rm -f "$t"; return 1; }
}

# _sg_run <timeout> <par> — one run of the gate; its exit code.
_sg_run() {
  local rc=0
  rm -rf "$BUILD/selection-gate"
  bin/selection-gate.sh --tree . --base "$BASE" --out "$BUILD/selection-gate" --timeout "$1" -P "$2" \
    > "$BUILD/selection-gate.txt" 2>&1 || rc=$?
  if [ -s "$BUILD/selection-gate/gate.txt" ]; then cp -f "$BUILD/selection-gate/gate.txt" "$BUILD/gate.txt"
  else rm -f "$BUILD/gate.txt"; fi
  return "$rc"
}

# sg_notice — one board comment for a red gate, built from $BUILD/gate.txt
#   only (a fixed template, no model). Only on a GitHub-Issues board with the
#   builder's direct path armed (the pb_notice condition); anywhere else rc 4
#   and the results sweep posts it (prompts/cromford.md, GATE_RED). A
#   second call for the same build posts nothing ($BUILD/gate-red-noticed).
#   rc 0 posted (SG_NOTED holds "<repo>#<num>"), 1 the post failed, 3 already
#   posted, 4 not this path.
sg_notice() {
  local root="${HARNESS:-${H:-}}" g="$BUILD/gate.txt" red n bp repo num bf
  SG_NOTED=""
  [ -e "$BUILD/gate-red-noticed" ] && { SG_NOTED=$(cat "$BUILD/gate-red-noticed" 2>/dev/null); return 3; }
  [ "${BUILDER_DIRECT_ON:-0}" = 1 ] && [ -n "$root" ] && [ -x "$root/bin/fleet-conf.sh" ] || return 4
  red=$(_sg_field "$g" red); [ -n "$red" ] && [ "$red" != - ] || return 4
  n=$(tr ',' '\n' <<<"$red" | grep -c .)
  bp=$("$root/bin/fleet-conf.sh" "$PROJECT" board_prefix 2>/dev/null) || bp=""
  [ "$bp" = - ] || return 4
  repo=$("$root/bin/fleet-conf.sh" "$PROJECT" repo 2>/dev/null) || repo=""
  case "${TICKET:-}" in ''|*[!0-9]*) num=$(sed -nE 's/^[A-Za-z]+-([0-9]+)$/\1/p' <<<"${KEY:-}") ;; *) num="$TICKET" ;; esac
  [ -n "$repo" ] && [ "$repo" != - ] && [ -n "$num" ] || return 4
  command -v gh_rest_comment >/dev/null 2>&1 || . "$root/bin/lib/gh-rest.sh" 2>/dev/null
  command -v gh_rest_comment >/dev/null 2>&1 || return 4
  bf=$(mktemp "${TMPDIR:-/tmp}/selection-gate-body.XXXXXX") || return 1
  {
    printf 'The build is done, but %s test suite(s) failed when we ran the full merge-queue selection for this change on our test host:\n\n' "$n"
    tr ',' '\n' <<<"$red" | sed 's/^/- `/; s/$/`/'
    printf '\nWe did not open a PR. Details are in the build record (gate.txt).\n'
  } > "$bf"
  if ! gh_rest_comment "$repo" "$num" "$bf"; then
    rm -f "$bf"; _sg_log "SELECTION-GATE notice NOT posted on $repo#$num (HTTP ${GH_REST_STATUS:-000}); the sweep posts it"
    return 1
  fi
  rm -f "$bf"
  SG_NOTED="$repo#$num"
  printf '%s\n' "$SG_NOTED" > "$BUILD/gate-red-noticed"
  _sg_log "SELECTION-GATE notice posted on $repo#$num"
  return 0
}

# sg_block — see the header. rc 0 go on, 6 red (RESULT written).
sg_block() {
  local to par fr rc red n line note=""
  SG_MARKER=""
  if [ ! -x bin/selection-gate.sh ]; then
    _sg_log "SELECTION-GATE skipped (repo carries no bin/selection-gate.sh)"; return 0
  fi
  if [ "$(_sg_knob SELECTION_GATE 1)" = 0 ]; then   # lane.fly-pool.selection_gate
    rm -rf "$BUILD/selection-gate"
    if sg_off_gate . "$BUILD/selection-gate"; then
      cp -f "$BUILD/selection-gate/gate.txt" "$BUILD/gate.txt"
      SG_MARKER=$(sg_marker "$BUILD/gate.txt") || SG_MARKER=""
      _sg_log "SELECTION-GATE off (SELECTION_GATE=0), record rc=off"
    else
      _sg_log "SELECTION-GATE off (SELECTION_GATE=0), no record (no HEAD)"
    fi
    return 0
  fi
  to=$(_sg_knob SELECTION_GATE_TIMEOUT_S 2400)       # lane.fly-pool.selection_gate_timeout_s
  par=$(_sg_knob SELECTION_GATE_P 12)                # lane.fly-pool.selection_gate_p
  fr=$(_sg_knob SELECTION_GATE_FIX_ROUNDS 0)         # lane.fly-pool.selection_gate_fix_rounds
  _sg_run "$to" "$par"; rc=$?
  if [ "$rc" = 1 ] && [ "$fr" -ge 1 ] && command -v CC >/dev/null 2>&1; then
    _sg_log "SELECTION-GATE red=[$(_sg_field "$BUILD/gate.txt" red)] -> one fix round"
    CC fix "${FIX_MODEL:-}" "$(_sg_knob SELECTION_GATE_FIX_TIMEOUT_S 1800)" "$BUILD/selection-gate-fix-run.txt" "The merge-queue test selection for branch ${BRANCH:-HEAD} is red on the test host in: $(_sg_field "$BUILD/gate.txt" red). The run output is in $BUILD/selection-gate/run.txt. Fix the code so those suites pass. Never weaken, skip or delete a test to get green. Commit your work. Do NOT push." || true
    _sg_run "$to" "$par"; rc=$?
  fi
  red=$(_sg_field "$BUILD/gate.txt" red); n=$(_sg_field "$BUILD/gate.txt" suites)
  _sg_log "SELECTION-GATE rc=$(_sg_field "$BUILD/gate.txt" rc) suites=${n:-?} red=${red:--} exit=$rc"
  if [ "$rc" = 1 ] && [ -n "$red" ] && [ "$red" != - ]; then
    if sg_notice; then
      command -v bd_note >/dev/null 2>&1 || . "${HARNESS:-${H:-}}/bin/lib/builder-direct.sh" 2>/dev/null
      command -v bd_note >/dev/null 2>&1 && note=$(bd_note "$SG_NOTED")
    fi
    line="GATE_RED $(tr ',' '\n' <<<"$red" | grep -c .) red: $red; see $BUILD/gate.txt"
    RESULT "$line$note"
    return 6
  fi
  sg_cnr_alert "$BUILD/gate.txt"
  SG_MARKER=$(sg_marker "$BUILD/gate.txt") || SG_MARKER=""
  return 0
}
