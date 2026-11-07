#!/bin/bash
# tests/hub-cron-gated-test.sh — the hub's crontab is LEASE-GATED.
#
# WHY THIS EXISTS. After the hub wipe of 2026-09-15, hub-ness is a lease
# (docs/verification-map/hub-lease.md), and this file is the half of it that
# actually stops a second box from acting: every hub-only lane in
# `cron/hub.cron` sits inside a `# BEGIN hub-lanes` / `# END hub-lanes` block,
# so the renderer puts `/root/harness/bin/hub-lease.sh check && ` in front of
# its command and the lane fires only on the box that currently holds the
# lease. One line is deliberately NOT gated — the `renew` line — because a box
# that never renews can never hold the lease it is being asked to prove.
#
# WHAT IT ASSERTS, and why each one is load-bearing:
#
#   S8  the renew line exists exactly once, at `* * * * *`, verbatim, and
#       OUTSIDE every block. Gate the renewer and the fleet has no hub at all.
#   S9  the gated set is exactly the in-block set: in-block job lines ==
#       prefixed lines, both > 0 (the `> 0` guard is what stops "delete every
#       marker" from passing as 0 == 0); no prefix outside a block; the named
#       box-local lines are PRESENT and unprefixed; the named fleet-wide lines
#       are present exactly once and prefixed. S9e: markers balanced, no empty
#       block, and no lane gated in the base's render runs ungated in this
#       one (diff-based; the old pinned block count is gone).
#   S13 `bin/render-crontab.sh hub` IS the checked-in file, and rendering the
#       render changes nothing — the file is a generated artifact.
#   S14 every in-block command, prefix and all, still parses as bash. A gated
#       lane that no longer parses does not skip, it errors every tick — this
#       is the assertion that covers `check && WINDOWS_ONLY=1 …` and the two
#       `for …; do …; done` compound lines.
#   S15 the mutation guard: strip the prefix off ONE gated line in a COPY and
#       S9a must report a mismatch. A suite that stays green under that is not
#       testing anything.
#
# Everything here asserts on the real cron/hub.cron and on the renderer's real
# output — never on the renderer's source text. Comparisons between files use
# `cmp`, never `$(...)` captures: command substitution eats trailing newlines,
# and a byte-for-byte check that cannot see the last byte is not one.
#
# No wall-clock read anywhere (bin/test-determinism-lint.sh).
#
# Run from anywhere: bash tests/hub-cron-gated-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# BH-1247: catalog/lanes.json and cron/<box>.cron are GENERATED and not
# committed. rendered_registry / rendered_cron render this repo's own into $T.
. "$(dirname "$0")/lib/rendered.sh" || exit 1
. "$(dirname "$0")/lib/ratchet-delta.sh" || exit 1
RENDER="$DIR/bin/render-crontab.sh"
CRON=$(rendered_cron hub)
PREFIX='/root/harness/bin/hub-lease.sh check && '
RENEW_LINE='* * * * * /root/harness/bin/hub-lease.sh renew >/dev/null 2>&1'
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

[ -x "$RENDER" ] || { echo "FAIL: bin/render-crontab.sh missing or not executable"; exit 1; }
[ -r "$CRON" ]   || { echo "FAIL: cron/hub.cron missing"; exit 1; }

# The job lines INSIDE hub-lanes blocks: markers, comments and blanks excluded.
# This is the set the renderer gates, so it is the set every count below is
# measured against.
inblock_jobs() {
  awk '
    /^# BEGIN hub-lanes/ { inb = 1; next }
    /^# END hub-lanes/   { inb = 0; next }
    inb && !/^[ \t\r]*$/ && !/^[ \t]*#/ { print }
  ' "$1"
}

# Everything OUTSIDE the blocks, markers excluded.
outblock_lines() {
  awk '
    /^# BEGIN hub-lanes/ { inb = 1; next }
    /^# END hub-lanes/   { inb = 0; next }
    !inb { print }
  ' "$1"
}

# The command half of every in-block schedule line — the five schedule fields
# split off with the SAME pattern bin/render-crontab.sh uses, so the test
# splits a line exactly where the renderer did.
inblock_commands() {
  inblock_jobs "$1" | awk '
    BEGIN { re = "^[0-9*][^ \t]*[ \t]+[^ \t]+[ \t]+[^ \t]+[ \t]+[^ \t]+[ \t]+[^ \t]+[ \t]+" }
    match($0, re) { print substr($0, RLENGTH + 1) }
  '
}

# S9a over an arbitrary file: "MATCH <n>" when the in-block job count equals the
# prefixed-line count and both are > 0, else "MISMATCH jobs=<n> prefixed=<n>".
# Written as a function so S15 can run the identical comparison over a mutant.
s9a_status() {
  local f="$1" jobs pre
  jobs=$(inblock_jobs "$f" | grep -c '' )
  pre=$(grep -cF "$PREFIX" "$f")
  if [ "$jobs" -gt 0 ] && [ "$pre" -gt 0 ] && [ "$jobs" = "$pre" ]; then
    echo "MATCH $jobs"
  else
    echo "MISMATCH jobs=$jobs prefixed=$pre"
  fi
}

inblock_jobs    "$CRON" > "$T/inblock"
outblock_lines  "$CRON" > "$T/outblock"

# ---------------------------------------------------------------------------
# S8 — the renew line: exactly one, verbatim, ungated, outside every block
# ---------------------------------------------------------------------------
S8A=$(grep -c 'hub-lease\.sh renew' "$CRON")
[ "$S8A" = 1 ] && ok || bad "S8a: expected exactly 1 'hub-lease.sh renew' line in cron/hub.cron, found $S8A"

grep -qxF "$RENEW_LINE" "$CRON" && ok \
  || bad "S8b: cron/hub.cron has no line exactly equal to: $RENEW_LINE"

grep -qF 'hub-lease.sh renew' "$T/inblock" \
  && bad "S8c: the renew line is INSIDE a hub-lanes block — a gated renewer can never take the lease" \
  || ok

# ---------------------------------------------------------------------------
# S9 — the gated set is exactly the in-block set
# ---------------------------------------------------------------------------
S9A=$(s9a_status "$CRON")
case "$S9A" in
  MATCH\ *) ok ;;
  *) bad "S9a: in-block job lines and prefixed lines disagree in cron/hub.cron ($S9A)" ;;
esac

S9B=$(grep -cF "$PREFIX" "$T/outblock")
[ "$S9B" = 0 ] && ok \
  || bad "S9b: $S9B line(s) OUTSIDE a hub-lanes block already carry the prefix — the renderer did not put them there:
$(grep -F "$PREFIX" "$T/outblock")"

# S9c — the box-local lines. Each must be PRESENT (so a deleted line fails here
# rather than passing vacuously), outside every block, and unprefixed.
UNGATED=(
  '/root/harness/bin/poll-commands.sh'
  '/root/harness/bin/watchdog-ping.sh box-hub'
  '/root/harness/bin/update-runners.sh'
  '/root/harness/bin/clock-sync.sh'
  '/root/harness/bin/harden-state.sh'
  '/root/harness/bin/quota-poll.sh'
  '/root/harness/bin/cost-rows-push.sh hub'
  '/root/harness/bin/extra-usage-track.sh hub'
  '17 16 29 07 *'
)
for U in "${UNGATED[@]}"; do
  N=$(grep -cF -- "$U" "$CRON")
  if [ "$N" -lt 1 ]; then
    bad "S9c: box-local line '$U' is GONE from cron/hub.cron"
    continue
  fi
  ok
  IN=$(grep -cF -- "$U" "$T/inblock")
  [ "$IN" = 0 ] && ok || bad "S9c: box-local line '$U' is inside a hub-lanes block"
  PRE=$(grep -F -- "$U" "$CRON" | grep -cF "$PREFIX")
  [ "$PRE" = 0 ] && ok || bad "S9c: box-local line '$U' carries the lease prefix"
done

# S9d — the fleet-wide lines. Exactly one line each, and it is five schedule
# fields followed immediately by the prefix.
GATED=(
  '/root/harness/bin/wake-loop.sh'
  # BH-1388: bin/merge-sweep.sh is no longer a hub cron LINE — the merge
  # conductor below is the hub's only merger. The script stays; the lane does
  # not, so there is no line here to be gated.
  '/root/harness/bin/merge-conductor.sh'
  '/root/harness/bin/fleet-propagate.sh'
  '/root/harness/bin/fly-dispatch.sh'
  '/root/harness/bin/vendor-spend-pull.sh'
  '/root/harness/bin/doorbell-coverage-check.sh'
  '/root/harness/bin/orc-monitor.sh'
  # P4: the daily route-shadow report is fleet-wide — one hub, lease-gated.
  '/root/harness/bin/route-shadow-report.sh'
)
GATED_RE="^[0-9*][^[:space:]]*([[:space:]]+[^[:space:]]+){4}[[:space:]]+/root/harness/bin/hub-lease\.sh check && "
for G in "${GATED[@]}"; do
  N=$(grep -cF -- "$G" "$CRON")
  if [ "$N" != 1 ]; then
    bad "S9d: expected exactly 1 line naming '$G' in cron/hub.cron, found $N"
    continue
  fi
  ok
  if grep -F -- "$G" "$CRON" | grep -Eq "$GATED_RE"; then ok
  else bad "S9d: the '$G' lane is not lease-gated: $(grep -F -- "$G" "$CRON")"; fi
done

# S9e — markers balanced, no empty block, and THIS DIFF UNGATES NO HUB LANE.
# The block COUNT used to be pinned (BLOCKS_EXPECTED, bumped 12 -> 13 -> ...):
# it is how the renderer happened to coalesce adjacent @hub-lanes fragments,
# so every new hub lane moved it and a lane dropping out of a block could as
# easily leave it unchanged. What the count stood in for is asserted directly
# instead, against the diff (tests/lib/ratchet-delta.sh): render the hub cron
# at the base (the newest main HEAD contains) with the base's own renderer,
# and no command gated there may run UNGATED here. A retired lane is simply
# absent; main's own moves are on both sides. A base that does not resolve, or
# does not render, is red. (A hub-scoped lane that declares neither
# `# @hub-lanes` nor `# @ungated <why>` is refused by bin/render-cron.sh
# itself: tests/registry-render-test.sh case 9.)
NB=$(grep -c '^# BEGIN hub-lanes' "$CRON")
NE=$(grep -c '^# END hub-lanes' "$CRON")
[ "$NB" = "$NE" ] && [ "$NB" -ge 1 ] && ok \
  || bad "S9e: expected balanced hub-lanes blocks, at least one, got BEGIN=$NB END=$NE"
EMPTY=$(awk '/^# BEGIN hub-lanes/ { inb = 1; n = 0; at = NR; next }
  /^# END hub-lanes/ { if (inb && n == 0) print at; inb = 0; next }
  inb && !/^[ \t\r]*$/ && !/^[ \t]*#/ { n++ }' "$CRON")
[ -z "$EMPTY" ] && ok || bad "S9e: hub-lanes block(s) with no job line, opened at line(s): $(echo $EMPTY)"

# s9e_ungated <base.cron> <head.cron> — every command gated in base that runs
# ungated (a schedule line outside every block) in head, one per line.
s9e_cmds_out() {
  outblock_lines "$1" | awk '
    BEGIN { re = "^[0-9*][^ \t]*[ \t]+[^ \t]+[ \t]+[^ \t]+[ \t]+[^ \t]+[ \t]+[^ \t]+[ \t]+" }
    match($0, re) { print substr($0, RLENGTH + 1) }' | sort -u
}
s9e_ungated() {
  inblock_commands "$1" | awk -v pre="$PREFIX" '{ i = index($0, pre); if (i == 1) print substr($0, length(pre) + 1); else print }' \
    | sort -u > "$T/s9e.gated"
  s9e_cmds_out "$2" > "$T/s9e.out"
  comm -12 "$T/s9e.gated" "$T/s9e.out"
}
# s9e_check <repo> <head.cron> — render hub at the base with the BASE's own
# renderer and compare; prints what is wrong, rc 1.
s9e_check() {
  local repo="$1" head="$2" base w ung
  base=$(rd_base "$repo") || { echo "$base"; return 1; }
  w=$(mktemp -d "$T/s9e.XXXXXX") || return 1
  if ! { rd_tree "$repo" "$base" "$w/t" bin cron catalog fleet.conf >/dev/null \
         && bash "$w/t/bin/render-cron.sh" --root "$w/t" hub > "$w/base.cron" 2>"$w/err" \
         && [ -s "$w/base.cron" ]; }; then
    echo "could not render cron/hub.cron at base ${base:0:12}: $(head -3 "$w/err" 2>/dev/null | tr '\n' ' ')"
    return 1
  fi
  ung=$(s9e_ungated "$w/base.cron" "$head")
  [ -z "$ung" ] && return 0
  echo "lane(s) lease-gated at base ${base:0:12} now run UNGATED on the hub — put the fragment back under '# @hub-lanes':"
  echo "$ung"
  return 1
}
OUT=$(s9e_check "$DIR" "$CRON") && ok || bad "S9e: $OUT"
# ...and s9e_check itself, in hermetic repos whose stub renderer prints the
# tree's own cron/stub.cron: THIS diff ungating a lane is red, main having
# done it is not, and no base is red.
s9e_repo() {
  scratch_rm "$1" || return 1; mkdir -p "$1/bin" "$1/cron" "$1/catalog"
  printf '#!/bin/bash\ncat "$2/cron/stub.cron"\n' > "$1/bin/render-cron.sh"
  { echo '# BEGIN hub-lanes'; printf '1 * * * * %s/root/harness/bin/a.sh\n' "$PREFIX"; echo '# END hub-lanes'
    echo ': pad 1'; echo ': pad 2'; echo ': pad 3'
    echo '# BEGIN hub-lanes'; printf '2 * * * * %s/root/harness/bin/b.sh\n' "$PREFIX"; echo '# END hub-lanes'; } > "$1/cron/stub.cron"
  : > "$1/fleet.conf"; rd_fixture_repo "$1"
}
# Ungating = the lane leaves its block (markers gone, prefix gone), which is
# what the renderer emits for a fragment that lost `# @hub-lanes`.
s9e_ungate_b() { sed -i -e '7d' -e '9d' -e "s|^2 \* \* \* \* $PREFIX|2 * * * * |" "$1/cron/stub.cron"; }
s9e_ungate_a() { sed -i -e '1d' -e '3d' -e "s|^1 \* \* \* \* $PREFIX|1 * * * * |" "$1/cron/stub.cron"; }
s9e_pr_docs()  { echo d >> "$1/README"; rd_git "$1" commit -qam docs; }
s9e_case() {  # <name> <want_rc> <steps...>
  local name="$1" want="$2" R="$T/s9e-$1" step out rc
  shift 2
  s9e_repo "$R" || { bad "S9e case $name: setup"; return; }
  for step in "$@"; do
    case "$step" in
      main-ungate-a) rd_main_commit "$R" 'main ungates a' s9e_ungate_a ;;
      merge)  rd_git "$R" merge -q --no-edit refs/remotes/origin/main ;;
      nomain) rd_git "$R" update-ref -d refs/remotes/origin/main ;;
      pr-ungate-b) s9e_ungate_b "$R" && rd_git "$R" commit -qam 'pr ungates b' ;;
      *) "$step" "$R" ;;
    esac >/dev/null 2>&1 || { bad "S9e case $name: step $step"; return; }
  done
  out=$(RATCHET_BASE= TI_BASE= s9e_check "$R" "$R/cron/stub.cron"); rc=$?
  [ "$rc" = "$want" ] && ok || bad "S9e case $name: rc=$rc want $want: $out"
}
s9e_case unchanged          0 s9e_pr_docs
s9e_case main-ungated-merged 0 s9e_pr_docs main-ungate-a merge
s9e_case pr-ungates         1 pr-ungate-b
s9e_case pr-ungates-after-drift 1 main-ungate-a pr-ungate-b merge
s9e_case no-base            1 s9e_pr_docs nomain
# The comparator itself, on hand-written crontabs: an ungated move is named, a
# retired lane and a rescheduled gated lane are not.
printf '# BEGIN hub-lanes\n* * * * * %s/root/harness/bin/a.sh\n5 * * * * %s/root/harness/bin/b.sh\n# END hub-lanes\n' "$PREFIX" "$PREFIX" > "$T/s9e-b.cron"
printf '# BEGIN hub-lanes\n* * * * * %s/root/harness/bin/a.sh\n# END hub-lanes\n5 * * * * /root/harness/bin/b.sh\n' "$PREFIX" > "$T/s9e-h1.cron"
printf '# BEGIN hub-lanes\n9 * * * * %s/root/harness/bin/a.sh\n# END hub-lanes\n' "$PREFIX" > "$T/s9e-h2.cron"
[ "$(s9e_ungated "$T/s9e-b.cron" "$T/s9e-h1.cron")" = /root/harness/bin/b.sh ] && ok \
  || bad "S9e: the comparator did not name a lane moved out of its block: '$(s9e_ungated "$T/s9e-b.cron" "$T/s9e-h1.cron")'"
[ -z "$(s9e_ungated "$T/s9e-b.cron" "$T/s9e-h2.cron")" ] && ok \
  || bad "S9e: a retired lane or a rescheduled gated lane read as ungated: '$(s9e_ungated "$T/s9e-b.cron" "$T/s9e-h2.cron")'"

BAL=$(awk '
  BEGIN { inb = 0; err = "" }
  /^# BEGIN hub-lanes/ { if (inb && err == "") err = "nested BEGIN at line " NR; inb = 1; next }
  /^# END hub-lanes/   { if (!inb && err == "") err = "END without BEGIN at line " NR; inb = 0; next }
  END { if (inb && err == "") err = "unterminated BEGIN"; print err }
' "$CRON")
[ -z "$BAL" ] && ok || bad "S9e: hub-lanes markers are unbalanced: $BAL"

# ---------------------------------------------------------------------------
# S13 — the checked-in file IS the render, and the render is idempotent
# ---------------------------------------------------------------------------
"$RENDER" hub > "$T/r1" 2>"$T/r1.err"
S13_RC=$?
[ "$S13_RC" = 0 ] && ok || bad "S13a: render-crontab.sh hub exited $S13_RC: $(cat "$T/r1.err")"
cmp -s "$T/r1" "$CRON" && ok \
  || bad "S13a: cron/hub.cron is not the render — regenerate it, never hand-edit:
$(diff "$CRON" "$T/r1" | head -25)"

"$RENDER" --base "$T/r1" hub > "$T/r2" 2>"$T/r2.err"
S13B_RC=$?
[ "$S13B_RC" = 0 ] && ok || bad "S13b: re-render exited $S13B_RC: $(cat "$T/r2.err")"
cmp -s "$T/r1" "$T/r2" && ok \
  || bad "S13b: render(render(hub)) != render(hub):
$(diff "$T/r1" "$T/r2" | head -25)"

# ---------------------------------------------------------------------------
# S14 — every gated command still parses (the production artifact, not a
# paraphrase of it). `check && WINDOWS_ONLY=1 …` and `check && for …; do …;
# done` are the two shapes that can break here.
# ---------------------------------------------------------------------------
inblock_commands "$CRON" > "$T/cmds"
NJOBS=$(grep -c '' < "$T/inblock")
NCMDS=$(grep -c '' < "$T/cmds")
if [ "$NCMDS" -gt 0 ] && [ "$NCMDS" = "$NJOBS" ]; then ok
else bad "S14: $NJOBS in-block job line(s) but only $NCMDS split into a command — a line inside a block is not a 5-field schedule line"; fi

SYNTAX_BAD=0
while IFS= read -r C; do
  bash -n <<<"$C" 2>>"$T/syntax.err" || { SYNTAX_BAD=$((SYNTAX_BAD+1)); echo "  $C" >> "$T/syntax.err"; }
done < "$T/cmds"
[ "$SYNTAX_BAD" = 0 ] && ok \
  || bad "S14: $SYNTAX_BAD gated command(s) do not parse as bash:
$(cat "$T/syntax.err")"

# ---------------------------------------------------------------------------
# S15 — mutation guard. Break exactly one gated line in a COPY and S9a must
# notice. Without this, every count above could be passing on any file.
# ---------------------------------------------------------------------------
if [ "$(grep -cF "$PREFIX" "$CRON")" -gt 0 ]; then
  awk -v pre="$PREFIX" '
    !done_one && index($0, pre) > 0 {
      i = index($0, pre)
      print substr($0, 1, i - 1) substr($0, i + length(pre))
      done_one = 1
      next
    }
    { print }
  ' "$CRON" > "$T/mutant"
  cmp -s "$T/mutant" "$CRON" \
    && bad "S15: the mutant is identical to cron/hub.cron — the mutation never happened" \
    || ok
  MUT=$(s9a_status "$T/mutant")
  case "$MUT" in
    MISMATCH\ *) ok ;;
    *) bad "S15: stripping the prefix off a gated line left S9a green ($MUT) — the suite does not detect an ungated lane" ;;
  esac
else
  bad "S15: no prefixed line in cron/hub.cron to mutate"
  bad "S15: mutation guard could not run"
fi

echo "hub-cron-gated-test: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ] || exit 1
