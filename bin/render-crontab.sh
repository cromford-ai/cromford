#!/bin/bash
# bin/render-crontab.sh [--root <dir>] [--base <file>|--base-live] <box-id>
#
# Print the crontab a box SHOULD have, derived from fleet.conf. Writes nothing;
# the caller pipes it to `crontab -` (bootstrap-machine.sh, update-runners.sh)
# or diffs it against the checked-in cron/<box-id>.cron (load-project.sh, CI).
#
# THE MODEL: managed blocks.
#
#   <every line the box already had, byte for byte>
#   # BEGIN fleet-managed project=<name>
#   ... the seven lanes, from bin/lib/cron-lines.sh ...
#   # END fleet-managed project=<name>
#
# Everything outside the markers is the operator's and is preserved exactly —
# @reboot, watchdog-ping, the hub's thirty orchestration lines, a box's weekly
# security scan, comments, SHELL=. The renderer only ever owns the blocks.
#
# THE ONE EXCEPTION, and it is the point of the whole change: an UNMARKED line
# that invokes a managed script for a project THIS BOX OWNS is absorbed into
# that project's block rather than preserved. That is the migration path off the
# hand-maintained files, and it is what makes the render converge — a lane
# installed by hand at 14:00 and a lane in the registry are the same lane, and
# the box must end up running exactly one of it.
#
# A box with no projects in fleet.conf (the hub, a parked box) renders byte-
# identical to its base. Inventing lanes for a stopped box is how it comes back
# to life on its own.
#
# HUB-LANES MARKERS. A second, independent marker pair gates lines behind the
# hub lease: every schedule line between `# BEGIN hub-lanes` and
# `# END hub-lanes` is rendered with `/root/harness/bin/hub-lease.sh check && `
# in front of its command, so the lane only fires on the box that currently
# holds the lease. The markers themselves are preserved, and a command that
# already carries exactly that prefix is left alone — which is what makes the
# checked-in file BE the render. Multiple blocks are allowed.
#
# Inside a block, only blank lines, `#` comments and five-field schedule lines
# are legal. Anything else — `SHELL=`, `@reboot`, a bare command — is FATAL:
# stderr names the line, the exit is non-zero, and stdout is EMPTY. A
# half-applied marker is a crontab nobody wrote.
#
# FLEET-WIDE FORM. `render-crontab.sh --from-fragments --all --write` rewrites
# every cron/<box>.cron from the per-lane fragments (BH-1178) by handing off to
# bin/render-cron.sh; that is the command guardrails/rendered-file-freshness
# names when somebody hand-edits a rendered crontab.
#
# The prefix goes BEFORE any `VAR=value` assignment (`check && WINDOWS_ONLY=1
# /root/...` is valid bash; the assignment scopes to the second command), and a
# `for ...; do ...; done` line is one compound command, gated whole. The
# renderer does not parse shell, so a top-level `;` inside a block separates
# the gate from what follows it and only the first command is gated.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
BASE=""; BASE_LIVE=0; BOX=""; FROM_FRAGMENTS=0; ALL=0; WRITE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --root)      ROOT="$2"; shift 2 ;;
    --base)      BASE="$2"; shift 2 ;;
    --base-live) BASE_LIVE=1; shift ;;
    --from-fragments) FROM_FRAGMENTS=1; shift ;;
    --all)       ALL=1; shift ;;
    --write)     WRITE=1; shift ;;
    # DERIVED, not a line number. The range used to be a literal '2,47p' and
    # this header grew past it twice — once silently (a paragraph documented in
    # a file nobody prints) and once loudly (-h printing five lines of code,
    # which tests/hub-lanes-render-test.sh catches). awk stops at the first line
    # that is not a comment, so the range moves with the header.
    -h|--help)   awk 'NR > 1 { if ($0 !~ /^#/) exit; print }' "$0"; exit 0 ;;
    --*)         echo "render-crontab.sh: unknown flag $1" >&2; exit 2 ;;
    *)           [ -z "$BOX" ] && BOX="$1" || { echo "render-crontab.sh: unexpected argument $1" >&2; exit 2; }; shift ;;
  esac
done

# --from-fragments --all --write is the fleet-wide entry point named by
# guardrails/rendered-file-freshness (bin/lib/render-fragments.sh rf_registry):
# rewrite every cron/<box>.cron from cron/lanes/ and cron/boxes/. The work is
# bin/render-cron.sh's — this is the one spelling the guardrail tells an author
# to run, kept here so the message names a command that exists. No recursion:
# render-cron.sh calls this script back WITHOUT --from-fragments, to splice the
# fleet-managed blocks into the base it composed.
if [ "$FROM_FRAGMENTS" = 1 ]; then
  [ "$ALL" = 1 ] && [ "$WRITE" = 1 ] || { echo "render-crontab.sh: --from-fragments needs --all --write" >&2; exit 2; }
  [ -z "$BOX" ] || { echo "render-crontab.sh: --from-fragments --all takes no box argument" >&2; exit 2; }
  exec "$HERE/render-cron.sh" --root "$ROOT" --all
fi
[ "$ALL" = 0 ] && [ "$WRITE" = 0 ] || { echo "render-crontab.sh: --all and --write are only valid with --from-fragments" >&2; exit 2; }
[ -n "$BOX" ] || { echo "usage: render-crontab.sh [--root dir] [--base file|--base-live] <box-id>  |  --from-fragments --all --write" >&2; exit 2; }

# shellcheck source=bin/lib/cron-lines.sh
. "$HERE/lib/cron-lines.sh"

# The registry the render is derived from. Exported so fleet-conf.sh and
# box-for.sh read the SAME file this run was pointed at (a test fixture, a box's
# /root/harness copy, or the checkout).
FLEET_CONF="$ROOT/fleet.conf"
export FLEET_CONF
# In REGISTRY_SOURCE=db the registry answers first (BH-5651), so a tree with no
# fleet.conf renders when fleet-conf.sh still lists projects from it.
[ -f "$FLEET_CONF" ] || { [ "${REGISTRY_SOURCE:-file}" = db ] && [ -n "$("$HERE/fleet-conf.sh" --projects 2>/dev/null)" ]; } \
  || { echo "render-crontab.sh: no fleet.conf at $FLEET_CONF" >&2; exit 1; }

# ---- which projects does the registry give this box? ------------------------
# In fleet.conf order, so the rendered file is stable and a re-render is a no-op.
PROJECTS=""
while read -r P; do
  [ -n "$P" ] || continue
  B=$("$HERE/box-for.sh" "$P" 2>/dev/null) || continue
  [ "$(cron_box_id_for "$B")" = "$BOX" ] || continue
  PROJECTS="$PROJECTS $P"
done < <("$HERE/fleet-conf.sh" --projects)

# ---- the base this render starts from ---------------------------------------
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
BASE_F="$TMP/base"
if [ "$BASE_LIVE" = 1 ]; then
  crontab -l 2>/dev/null > "$BASE_F" || : > "$BASE_F"
elif [ -n "$BASE" ]; then
  cp "$BASE" "$BASE_F"
elif [ -x "$HERE/render-cron.sh" ] && [ -d "$ROOT/cron/lanes" ]; then
  # THE RENDER WINS OVER ANY FILE ON DISK (BH-1247, review I1). cron/<box>.cron
  # used to be committed and this branch simply copied it. It is generated and
  # GIT-IGNORED now, which changes what "a copy on disk" means: `git status`
  # does not show it, `git pull` never deletes it, and every operator-facing doc
  # still tells a human to run `bin/render-cron.sh --all` — which, run once in a
  # box checkout, would leave a frozen base that silently wins every future
  # install while the fragments move underneath it. So when the fragments are
  # here, they are the answer, full stop.
  #
  # `-d "$ROOT/cron/lanes"` is part of the condition and not an error inside the
  # branch: a tree with a crontab but no fragments (a fixture that supplies its
  # own base, a deployed /root/harness — bin/harness-sync.sh deploys bin/ and
  # catalog/ but NOT cron/) still falls through to the branch below.
  #
  # FAIL CLOSED once we have committed to rendering, and DELIBERATELY not back
  # to the on-disk copy. A render that failed tells us nothing about what this
  # box should run, and the file it would fall back to is exactly the stale,
  # invisible copy this branch exists to stop trusting. Falling back would also
  # turn a LOUD failure into a silent stale install: bin/update-runners.sh and
  # bin/fleet-propagate.sh both read a non-zero rc here as "touch nothing and
  # write CRONTAB RENDER FAILED to ALERTS", and an rc 0 carrying stale lines
  # would install them with no alert at all.
  if ! "$HERE/render-cron.sh" --root "$ROOT" "$BOX" > "$BASE_F" 2>"$TMP/base.err"; then
    echo "render-crontab.sh: could not render the base crontab for box $BOX — refusing to render on top of nothing:" >&2
    head -5 "$TMP/base.err" >&2
    [ -f "$ROOT/cron/$BOX.cron" ] \
      && echo "render-crontab.sh:   NOTE $ROOT/cron/$BOX.cron exists but is NOT used — it is a generated, git-ignored artifact (BH-1247) and may be any age. Fix the fragments, or delete it." >&2
    exit 1
  fi
  [ -s "$BASE_F" ] || { echo "render-crontab.sh: the rendered base for box $BOX is EMPTY — refusing it" >&2; exit 1; }
elif [ -f "$ROOT/cron/$BOX.cron" ]; then
  # No fragments in this tree, so there is nothing to render FROM and the file
  # on disk is the only base there is: a hand-managed box that captured its live
  # crontab with --base-live, a test fixture that wrote its own.
  cp "$ROOT/cron/$BOX.cron" "$BASE_F"
else
  : > "$BASE_F"
fi

# ---- hub-lanes marker pass -----------------------------------------------
# Wraps crontab lines inside # BEGIN hub-lanes / # END hub-lanes blocks with a
# hub-lease.sh check && prefix. Lines inside a block may only be 5-field cron
# schedule lines, blank lines, and # comments; anything else is fatal.
#
# The schedule pattern anchors the minute field on [0-9*], not on "any character
# that is not a space, # or @". A cron minute never starts with anything else,
# and the looser anchor is exactly what lets a BARE COMMAND of six or more words
# read as "five fields plus a command": the prefix then lands in the MIDDLE of
# the command and the render still exits 0. Half-applying a marker is the one
# outcome this pass must never have.
#
# The four schedule-field repetitions are written out rather than {4}: mawk
# 1.3.4's interval expression does not match this pattern on a command carrying
# `--flags` (probed on this fleet's awk), so the dialect would decide which
# lines are legal. Expanded, every awk agrees.
#
# `bailed` exists because awk's `exit` from a rule still runs END. Without it
# the END guard overwrites every in-block refusal with the dangling-BEGIN code
# and message, so a `SHELL=` line inside a block reports an unterminated marker
# and the operator repairs the wrong thing.
HUB_LANES_AWK='
function die(code, msg) { printf "%s\n", msg > "/dev/stderr"; bailed = 1; exit code }
BEGIN { inblock = 0; block_start = 0; bailed = 0
        sched_re = "^[0-9*][^ \t]*[ \t]+[^ \t]+[ \t]+[^ \t]+[ \t]+[^ \t]+[ \t]+[^ \t]+[ \t]+" }
/^# BEGIN hub-lanes/ {
  if (inblock) die(4, sprintf("BEGIN inside a hub-lanes block at line %d (block opened at line %d)", NR, block_start))
  inblock = 1; block_start = NR; print; next }
/^# END hub-lanes/ {
  if (!inblock) die(5, sprintf("END without matching BEGIN at line %d", NR))
  inblock = 0; print; next }
inblock == 1 {
  if (/^[ \t\r]*$/) { print; next }
  if (/^[ \t]*#/) { print; next }
  if (match($0, sched_re)) {
    sched = substr($0, 1, RLENGTH)
    cmd = substr($0, RLENGTH + 1)
    if (cmd !~ /^\/root\/harness\/bin\/hub-lease\.sh check && /) {
      cmd = "/root/harness/bin/hub-lease.sh check && " cmd
    }
    print sched cmd
    next
  }
  die(6, sprintf("Illegal line inside hub-lanes block at line %d: %s", NR, $0))
}
{ print }
END {
  if (!bailed && inblock) die(3, sprintf("Unterminated \"# BEGIN hub-lanes\" marker at line %d", block_start))
}
'

# hub_lanes_apply <file> — pipe through the hub-lanes awk, emit output only on
# success. Non-zero exit -> stdout is empty, stderr carries the error. Buffering
# the whole render before printing a byte of it is the point: a caller that pipes
# us straight into `crontab -` must get NOTHING when the markers are broken.
#
# Routing the no-projects shortcut through awk instead of `cat` also terminates a
# base whose last line has no newline, which `cat` used to pass through. The
# normal path has always done that (its strip pass is awk too), `crontab -l`
# always ends in a newline, and `crontab -` wants one — so this makes the two
# paths agree rather than changing what any box gets.
hub_lanes_apply() {
  local f="$1" rc=0
  set +e
  awk "$HUB_LANES_AWK" "$f" > "$TMP/hl-out" 2>"$TMP/hl-err"
  rc=$?
  set -e
  if [ "$rc" = 0 ]; then
    cat "$TMP/hl-out"
    return 0
  fi
  cat "$TMP/hl-err" >&2
  case "$rc" in
    3) echo "render-crontab.sh: unterminated '# BEGIN hub-lanes' marker in $BASE_F (no matching END). Refusing to render." >&2 ;;
    4) echo "render-crontab.sh: nested '# BEGIN hub-lanes' marker inside another block in $BASE_F. Refusing to render." >&2 ;;
    5) echo "render-crontab.sh: '# END hub-lanes' with no matching BEGIN in $BASE_F. Refusing to render." >&2 ;;
    6) echo "render-crontab.sh: illegal line inside hub-lanes block in $BASE_F (only 5-field cron schedule lines, blank lines, and # comments allowed). Refusing to render." >&2 ;;
    *) echo "render-crontab.sh: hub-lanes pass failed (awk rc=$rc) on $BASE_F" >&2 ;;
  esac
  return "$rc"
}

# No projects here: the base IS the answer, but it still runs through the
# hub-lanes pass so marker-less files render byte-identical and marker files
# get their prefixes regardless of which path the renderer takes.
if [ -z "$PROJECTS" ]; then
  hub_lanes_apply "$BASE_F"
  exit $?
fi

# ---- the generated blocks ---------------------------------------------------
BLOCKS="$TMP/blocks"; : > "$BLOCKS"
ALT=""
# merge-queue and review-prs minutes already taken on this box, in fleet.conf
# order: a later project whose derived minute is taken moves to the next free one.
MQ_USED=""; RP_USED=""
# review-prs interval per project (BH-7513), read once from the settings rows.
# RP_PLAN holds "<project>=<interval>=<start minute>" for every project.
# THE 30-MINUTE PROJECTS ARE PLACED FIRST, in fleet.conf order and against the
# same used list as before, so a project with no row renders byte-identical to
# what it always did whatever its neighbours run. The 10 and 15 minute ones take
# the slots that are left; one with no distinct set keeps 30 and logs one line.
RP_IV=$(cron_review_intervals "${HARNESS:-$ROOT}" $PROJECTS)
RP_PLAN=""
rp_kv() { printf '%s\n' $1 | awk -F= -v k="$2" -v f="$3" '$1 == k { print $f; exit }'; }
for P in $PROJECTS; do
  IV=$(awk -v p="$P" '$1 == p { print $2; exit }' <<<"$RP_IV")
  case "$IV" in 10|15) continue ;; esac
  OFF=$("$HERE/fleet-conf.sh" "$P" offset)
  case "$OFF" in ''|*[!0-9]*) echo "render-crontab.sh: $P has a non-numeric cron offset '$OFF'" >&2; exit 1 ;; esac
  RP=$(cron_stagger_min "$(( (7 + 10#$OFF) % 30 ))" 30 "$RP_USED"); RP_USED="$RP_USED $RP"
  RP_PLAN="$RP_PLAN $P=30=$RP"
done
for P in $PROJECTS; do
  IV=$(awk -v p="$P" '$1 == p { print $2; exit }' <<<"$RP_IV")
  case "$IV" in 10|15) ;; *) continue ;; esac
  OFF=$("$HERE/fleet-conf.sh" "$P" offset)
  case "$OFF" in ''|*[!0-9]*) echo "render-crontab.sh: $P has a non-numeric cron offset '$OFF'" >&2; exit 1 ;; esac
  if RP=$(cron_review_slot "$IV" "$(( (7 + 10#$OFF) % IV ))" "$RP_USED"); then
    RP_USED="$RP_USED $(cron_review_residues "$IV" "$RP")"
  else
    echo "render-crontab.sh: review-prs interval $IV for $P has no distinct minute set on box $BOX; keeping 30" >&2
    IV=30; RP=$(cron_stagger_min "$(( (7 + 10#$OFF) % 30 ))" 30 "$RP_USED"); RP_USED="$RP_USED $RP"
  fi
  RP_PLAN="$RP_PLAN $P=$IV=$RP"
done
for P in $PROJECTS; do
  OFF=$("$HERE/fleet-conf.sh" "$P" offset)
  PROD=$("$HERE/fleet-conf.sh" "$P" prod)
  case "$OFF" in ''|*[!0-9]*) echo "render-crontab.sh: $P has a non-numeric cron offset '$OFF'" >&2; exit 1 ;; esac
  MQ=$(cron_stagger_min "$(( (6 + 10#$OFF) % 20 ))" 20 "$MQ_USED"); MQ_USED="$MQ_USED $MQ"
  cron_project_block "$P" "$OFF" "$PROD" "$ROOT" "$MQ" "$(rp_kv "$RP_PLAN" "$P" 3)" "$(rp_kv "$RP_PLAN" "$P" 2)" >> "$BLOCKS"
  # Project names are [a-z0-9-] by convention; escape anyway so a name can never
  # become a regex.
  ALT="$ALT|$(printf '%s' "$P" | sed 's/[][\\.*^$(){}?+|/]/\\&/g')"
done
ALT="${ALT#|}"

# ---- strip the old, mark where the new goes ---------------------------------
# One pass: drop every marked block and every unmarked managed line for one of
# our projects, and leave a single sentinel at the position of the FIRST thing
# dropped, so the blocks land where the box's project lanes already were rather
# than at the end of the file. Nothing dropped -> sentinel at the end.
#
# THE MARKERS MUST BE BALANCED, and a violation is FATAL rather than tolerated.
# `inblock` swallows every line until its END, so a dangling BEGIN with no END
# silently deletes the whole rest of the file — and the result still exits 0
# with plausible non-empty output (the block's own run-triage line is right
# there), so neither an empty-output check nor the drift guard can catch it.
# On a real box that is the @reboot sshd/cron/tailscaled line and the watchdog
# ping gone: unreachable after the next reboot, and pinging nothing until then.
# A truncated write is exactly how such a file appears, so this is not
# hypothetical. Exit non-zero and let every caller keep its live crontab.
set +e
awk -v scripts="$(cron_managed_scripts)" -v projs="$ALT" '
  # \r belongs in the tail class. Without it a CRLF-terminated managed line
  # fails to match, so it is PRESERVED as an unknown line while a fresh block is
  # also generated — the box then runs that lane twice, permanently, and
  # idempotence keeps passing because the doubled state is stable. Files pick up
  # CRLF from a Windows editor, a clipboard round-trip, or a converting scp.
  BEGIN { inblock = 0; placed = 0
          re = "/root/harness/bin/(" scripts ")\\.sh[ \t]+(" projs ")([ \t\r]|$)" }
  function place() { if (!placed) { print "@@FLEET_BLOCKS@@"; placed = 1 } }
  /^# BEGIN fleet-managed project=/ {
    if (inblock) exit 4               # BEGIN inside a block: nested/duplicated
    place(); inblock = 1; next }
  /^# END fleet-managed project=/ {
    if (!inblock) exit 5              # END with no BEGIN: the file is corrupt
    inblock = 0; next }
  inblock { next }
  /^[ \t]*#/ { print; next }
  $0 ~ re   { place(); next }
  { print }
  END { if (inblock) exit 3           # dangling BEGIN: the rest of the file
        place() }                     # was swallowed — refuse to emit it
' "$BASE_F" > "$TMP/stripped"
AWK_RC=$?
set -e
case "$AWK_RC" in
  0) ;;
  3) echo "render-crontab.sh: $BASE_F has an unterminated '# BEGIN fleet-managed' marker (no matching END). Refusing to render: everything after a dangling BEGIN is silently swallowed, which on a live box means losing @reboot and the watchdog ping. Repair the file's markers." >&2; exit 3 ;;
  4) echo "render-crontab.sh: $BASE_F has a '# BEGIN fleet-managed' marker inside another block. Refusing to render; repair the file's markers." >&2; exit 3 ;;
  5) echo "render-crontab.sh: $BASE_F has a '# END fleet-managed' marker with no matching BEGIN. Refusing to render; repair the file's markers." >&2; exit 3 ;;
  *) echo "render-crontab.sh: the strip pass failed (awk rc=$AWK_RC) on $BASE_F" >&2; exit "$AWK_RC" ;;
esac

awk -v bf="$BLOCKS" '
  $0 == "@@FLEET_BLOCKS@@" { while ((getline l < bf) > 0) print l; close(bf); next }
  { print }
' "$TMP/stripped" > "$TMP/spliced"

# ---- apply the hub-lanes pass on the normal path --------------------------
hub_lanes_apply "$TMP/spliced"
