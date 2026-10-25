# bin/blocked-resolver.d/bh-8062-selection-gate.sh — BH-8062 r3 (F3): a fix
# round runs the selection gate and refreshes the PR's record.
#
# WHY. The builder runs the merge-queue batch's selection on the fleet test
# host before it opens a PR and writes `<!-- selection-gate: head=… -->` into
# the body (bin/lib/selection-gate.sh). The lead review refuses MERGE when that
# record names another head (bin/lib/lead-review/gate-record.sh). br_fix_round
# pushes straight to the PR branch, outside the builder, so without this every
# fixed PR's record names the old head and the review refuses it.
#
# br_sg_verify runs inside the round's verify group: red refuses the push like
# a red unit run (the driver's `(…|SELECTION_GATE)_EXIT: [1-9]` grep).
# br_sg_after_push rewrites the body's record after a push that landed, only
# for a gate.txt of that head and only when it is not red. Both are fail-open:
# a record that is not refreshed leaves the review refusing that head, which is
# the right answer for a head with no record.
#
# Functions only, no variable at source time, no exit. The root is ${H:-} only.

# br_sg_verify <wt> <main-ref> <outdir> [<project>] — stdout: the verify block.
#   `== selection-gate ==`, then one `SELECTION_GATE_EXIT: <word>` line:
#     0                   green
#     1                   red; a `SELECTION_GATE_RED: <suites>` line follows
#     could-not-run <why> the host could not answer (never a refusal)
#     no-selection        the selection was empty (never a refusal)
#     skipped (<why>)     no bin/selection-gate.sh in the worktree (every other
#                         repo), SELECTION_GATE=0 (an rc=off <outdir>/gate.txt
#                         is written), or no lib on this box
#   The gate's own output goes to <outdir>/run.out, never to stdout.
br_sg_verify() {
  local wt="${1:-}" mref="${2:-origin/main}" od="${3:-}" proj="${4:-}" to par rc=0 red why
  echo "== selection-gate =="
  if [ ! -x "$wt/bin/selection-gate.sh" ]; then echo "SELECTION_GATE_EXIT: skipped (no bin/selection-gate.sh)"; return 0; fi
  command -v _sg_knob >/dev/null 2>&1 || . "${H:-}/bin/lib/selection-gate.sh" 2>/dev/null
  command -v _sg_knob >/dev/null 2>&1 || { echo "SELECTION_GATE_EXIT: skipped (no bin/lib/selection-gate.sh on this box)"; return 0; }
  if [ "$(PROJECT="$proj" _sg_knob SELECTION_GATE 1)" = 0 ]; then   # lane.fly-pool.selection_gate
    # An rc=off record of the worktree head, so br_sg_after_push refreshes the
    # body and the lead review does not refuse the pushed head as missing.
    if [ -n "$od" ]; then rm -rf "$od"; mkdir -p "$od" 2>/dev/null; sg_off_gate "$wt" "$od" || true; fi
    echo "SELECTION_GATE_EXIT: skipped (SELECTION_GATE=0)"; return 0
  fi
  [ -n "$od" ] || { echo "SELECTION_GATE_EXIT: could-not-run no-outdir"; return 0; }
  to=$(PROJECT="$proj" _sg_knob SELECTION_GATE_TIMEOUT_S 2400)   # lane.fly-pool.selection_gate_timeout_s
  par=$(PROJECT="$proj" _sg_knob SELECTION_GATE_P 12)            # lane.fly-pool.selection_gate_p
  rm -rf "$od"; mkdir -p "$od" 2>/dev/null
  "$wt/bin/selection-gate.sh" --tree "$wt" --base "$mref" --out "$od" --timeout "$to" -P "$par" > "$od/run.out" 2>&1 || rc=$?
  why=$(sed -n 's/^why: //p' "$od/gate.txt" 2>/dev/null | head -n 1)
  case "$rc" in
    0) echo "SELECTION_GATE_EXIT: 0" ;;
    1) red=$(sed -n 's/^red: //p' "$od/gate.txt" 2>/dev/null | head -n 1)
       echo "SELECTION_GATE_EXIT: 1"; echo "SELECTION_GATE_RED: ${red:--}"
       declare -F say >/dev/null 2>&1 && say "selection gate red on the fix round's head in ${wt##*/}: ${red:--} (see $od/gate.txt) — not pushed" ;;
    4) echo "SELECTION_GATE_EXIT: no-selection" ;;
    *) echo "SELECTION_GATE_EXIT: could-not-run ${why:-rc-$rc}" ;;
  esac
  return 0
}

# br_sg_after_push <slug> <pr-url> <new-head> <outdir> — after a fix round's
#   push: when <outdir>/gate.txt names <new-head> and its rc is not 1, the PR
#   body's selection-gate record is set to that gate.txt (sg_marker_replace)
#   and the body is PATCHed. One `say` line either way. rc 0 always.
br_sg_after_push() {
  local slug="${1:-}" url="${2:-}" nh="${3:-}" od="${4:-}" g num mk raw body bf
  g="$od/gate.txt"
  [ -s "$g" ] || return 0
  command -v sg_marker_replace >/dev/null 2>&1 || . "${H:-}/bin/lib/selection-gate.sh" 2>/dev/null
  command -v sg_marker_replace >/dev/null 2>&1 || { declare -F say >/dev/null 2>&1 && say "$slug: selection-gate record not refreshed (no bin/lib/selection-gate.sh on this box)"; return 0; }
  num="${url##*/}"
  case "$num" in ''|*[!0-9]*) return 0 ;; esac
  if [ "$(_sg_field "$g" head)" != "$nh" ] || [ "$(_sg_field "$g" rc)" = 1 ] || ! mk=$(sg_marker "$g"); then
    say "$slug#$num: selection-gate record not refreshed: gate.txt is for head $(_sg_field "$g" head | cut -c1-8), rc $(_sg_field "$g" rc), not a record for the pushed head ${nh:0:8}"
    return 0
  fi
  # gh_rest_var, never `$( )`: GH_REST_STATUS must survive for the say line.
  command -v gh_rest_var >/dev/null 2>&1 || . "${H:-}/bin/lib/gh-rest-var.sh" 2>/dev/null
  command -v gh_rest_var >/dev/null 2>&1 || { say "$slug#$num: selection-gate record not refreshed (no bin/lib/gh-rest-var.sh on this box)"; return 0; }
  # Two steps, never a pipe: a failed read must not become an empty body that
  # the PATCH below would write over the real one.
  raw=""
  if ! gh_rest_var raw GET "repos/$slug/pulls/$num" 2>/dev/null \
     || ! jq -e 'type == "object" and has("body")' >/dev/null 2>&1 <<<"$raw" \
     || ! body=$(jq -r '.body // ""' <<<"$raw" 2>/dev/null); then
    say "$slug#$num: selection-gate record not refreshed: the PR body could not be read (HTTP ${GH_REST_STATUS:-000})"; return 0
  fi
  bf=$(mktemp "${TMPDIR:-/tmp}/br-sg-body.XXXXXX") || return 0
  sg_marker_replace "$body" "$mk" > "$bf"
  if gh_rest PATCH "repos/$slug/pulls/$num" -F "body=@$bf" >/dev/null 2>&1; then
    say "$slug#$num: selection-gate record set to the pushed head ${nh:0:8} (rc $(_sg_field "$g" rc), $(_sg_field "$g" suites) suites)"
  else
    say "$slug#$num: selection-gate record not refreshed: the body PATCH failed (HTTP ${GH_REST_STATUS:-000})"
  fi
  rm -f "$bf"
  return 0
}
