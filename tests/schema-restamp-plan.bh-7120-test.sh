#!/bin/bash
# tests/schema-restamp-plan.bh-7120-test.sh — BH-7120: a restamp
# (bin/lib/schema-restamp.sh) also renames the fragment in the PR's
# .harness/specs/<KEY>/plan.md, in the same commit, so pr-self-check plan-files
# (psc_plan_missing, bin/lib/pr-self-check.sh) passes on the restamped head, and
# sr_commit_only accepts that plan.md edit and nothing more.
#
#   P1  plan.md names the old full path: renamed, psc_plan_missing empty
#   P2  plan.md names <UTC-minute>-… and <stamp>-… placeholders (PR #7055's
#       shape): both name the new path, psc_plan_missing empty
#   P3  sr_commit_only rc 0 on the P1 and P2 commits; restamp_same says restamp
#   P6  another suffix, another dir, no dir, 10 digits, a plan path one level
#       deeper and a docs file keep their placeholders byte for byte
#   P7  sr_text_rewrite turns a body reason line to the new path, rc 0; rc 1 on
#       a second call
#   P8  two fragments in one dir: each placeholder maps to its own new name
#   P9  a broken python3: sr_apply rc 2, HEAD unchanged
#   N1  the restamp commit plus one extra plan.md line: sr_commit_only rc 1
#   N2  a placeholder rewritten to a stamp that is not the new name: rc 1
#   N3  a placeholder rewritten in docs/x.md: rc 1
#   N4  a plan.md edit with no rename: rc 1
#   N5  an equal-plan edit in .harness/specs/BH-6889/sub/plan.md: rc 1
# Real git; no network. Run from anywhere:
#   HARNESS_TEST_SANDBOX=1 bash tests/schema-restamp-plan.bh-7120-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v python3 >/dev/null || { echo "python3 missing — skipping"; exit 0; }
# shellcheck source=bin/lib/schema-restamp.sh
. "$DIR/bin/lib/schema-restamp.sh" || { echo "FAIL: cannot source bin/lib/schema-restamp.sh"; exit 1; }
# shellcheck source=bin/lib/pr-self-check.sh
. "$DIR/bin/lib/pr-self-check.sh" || { echo "FAIL: cannot source bin/lib/pr-self-check.sh"; exit 1; }

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
export SR_NOW_EPOCH
SR_NOW_EPOCH=$(date -u -d '2026-10-16 06:44' +%s)
SD=worker/jobs/schema.d
OLD=202610160227-bh-6889-alert-lines.sql
NEW=202610160644-bh-6889-alert-lines.sql
PLAN=.harness/specs/BH-6889/plan.md
R="$T/repo"
EMPTY="$T/empty-body.md"; : > "$EMPTY"

g() { git -C "$R" "$@"; }
commit() { g add -A; g commit -qm "$1"; }
# seed <plan-text-file> [fragment...] — main: 202610140000-bh-0-z at the fork,
#   then 202610160500-bh-1-a. Branch pr (checked out at the end) adds each
#   fragment (default $OLD) and $PLAN with the given text.
seed() {
  local pt="$1" f; shift
  [ "$#" -gt 0 ] || set -- "$OLD"
  scratch_rm "$R" 2>/dev/null
  mkdir -p "$R/$SD" "$R/${PLAN%/*}"; g init -q -b main
  printf 'CREATE TABLE z (id INTEGER);\n' > "$R/$SD/202610140000-bh-0-z.sql"
  commit base
  g checkout -qb pr
  for f in "$@"; do printf 'CREATE TABLE t_%s (id INTEGER);\n' "${#f}" > "$R/$SD/$f"; done
  cp "$pt" "$R/$PLAN"
  commit pr
  g checkout -q main
  printf 'CREATE TABLE a (id INTEGER);\n' > "$R/$SD/202610160500-bh-1-a.sql"
  commit main-a
  g checkout -q pr
  PRE=$(g rev-parse HEAD)
}
missing() { psc_plan_missing "$R" main HEAD "${1:-$EMPTY}"; }

# ── P1: the old full path ──
cat > "$T/p1.md" <<EOF
# plan

## Files to touch
- \`$SD/$OLD\` — the alert lines table.
- \`$PLAN\` — this plan.

## Tasks
EOF
seed "$T/p1.md"
m=$(missing); [ -z "$m" ] && ok || bad "P1 setup: the plan names the old path, so nothing is missing before the restamp; got '$m'"
new=$(sr_apply "$R" main); rc=$?
[ "$rc" = 0 ] && [ "$new" = "$(g rev-parse HEAD)" ] && [ "$(g rev-list --count "$PRE..HEAD")" = 1 ] && ok || bad "P1 sr_apply rc=$rc new='$new'"
[ "$(g log -1 --format=%s)" = 'restamp schema fragments (no SQL change)' ] && ok || bad "P1 subject: $(g log -1 --format=%s)"
g show --name-only --format= HEAD | grep -qxF "$PLAN" && ok || bad "P1 plan.md must be in the restamp commit"
grep -qF "$SD/$NEW" "$R/$PLAN" && ! grep -qF "$OLD" "$R/$PLAN" && ok || bad "P1 plan.md must name the new path only: $(cat "$R/$PLAN")"
m=$(missing); rc=$?
[ "$rc" = 0 ] && [ -z "$m" ] && ok || bad "P1 psc_plan_missing after the restamp: rc=$rc '$m'"
sr_commit_only "$R" HEAD && ok || bad "P3 sr_commit_only must accept the P1 restamp commit"
how=$(restamp_same "$R" main "$PRE" HEAD); [ "$how" = restamp ] && ok || bad "P3 restamp_same on P1: '$how'"

# ── P2: placeholders (PR #7055's shape) ──
cat > "$T/p2.md" <<EOF
# plan

## Files to touch
- \`$SD/<UTC-minute>-bh-6889-alert-lines.sql\` — new fragment.
- \`$PLAN\` — this plan.

## Tasks
### T4. \`$SD/<stamp>-bh-6889-alert-lines.sql\`
Done in $SD/<stamp>-bh-6889-alert-lines.sql.
EOF
seed "$T/p2.md"
m=$(missing); [ "$m" = "$SD/$OLD" ] && ok || bad "P2 setup: the placeholder plan misses the old path before the restamp; got '$m'"
new=$(sr_apply "$R" main); rc=$?
[ "$rc" = 0 ] && [ "$(g rev-list --count "$PRE..HEAD")" = 1 ] && ok || bad "P2 sr_apply rc=$rc"
want=$(sed -e "s#<UTC-minute>-bh-6889#${NEW%%-*}-bh-6889#; s#<stamp>-bh-6889#${NEW%%-*}-bh-6889#g" "$T/p2.md")
[ "$(cat "$R/$PLAN")" = "$want" ] && ok || bad "P2 plan.md: want every placeholder as the new path, got: $(cat "$R/$PLAN")"
[ "$(grep -cF "$SD/$NEW" "$R/$PLAN")" = 3 ] && ok || bad "P2 want 3 lines naming the new path"
m=$(missing); rc=$?
[ "$rc" = 0 ] && [ -z "$m" ] && ok || bad "P2 psc_plan_missing after the restamp: rc=$rc '$m'"
sr_commit_only "$R" HEAD && ok || bad "P3 sr_commit_only must accept the P2 restamp commit"
how=$(restamp_same "$R" main "$PRE" HEAD); [ "$how" = restamp ] && ok || bad "P3 restamp_same on P2: '$how'"
P2HEAD=$(g rev-parse HEAD)

# ── N1: the P2 restamp plus one extra plan line, one commit ──
g reset -q --soft "$PRE"; echo 'smuggled line' >> "$R/$PLAN"; g add -A; g commit -qm 'restamp schema fragments (no SQL change)'
sr_commit_only "$R" HEAD && bad "N1 a plan.md with one extra line must be refused" || ok
# ── N2: the placeholder rewritten to another stamp ──
g reset -q --hard "$P2HEAD"; g reset -q --soft "$PRE"
sed -i "0,/${NEW%%-*}/s//202610160700/" "$R/$PLAN"
grep -qF 202610160700 "$R/$PLAN" || bad "N2 setup: the other stamp was not written"
g add -A; g commit -qm x
sr_commit_only "$R" HEAD && bad "N2 a placeholder rewritten to a stamp that is not the new name must be refused" || ok

# ── N3: a placeholder rewritten in a docs file ──
cat > "$T/n3.md" <<EOF
## Files to touch
- \`$SD/$OLD\` — x
EOF
seed "$T/n3.md"
mkdir -p "$R/docs"; printf 'see %s/<stamp>-bh-6889-alert-lines.sql\n' "$SD" > "$R/docs/x.md"; commit docs
PRE=$(g rev-parse HEAD)
g mv "$SD/$OLD" "$SD/$NEW"
printf 'see %s/%s\n' "$SD" "$NEW" > "$R/docs/x.md"; sed -i "s#$OLD#$NEW#" "$R/$PLAN"
g add -A; g commit -qm x
sr_commit_only "$R" HEAD && bad "N3 a placeholder rewrite outside plan.md must be refused" || ok

# ── N4: a plan.md edit with no rename ──
seed "$T/p2.md"
sed -i "s#<UTC-minute>-bh-6889#${NEW%%-*}-bh-6889#" "$R/$PLAN"; g add -A; g commit -qm x
sr_commit_only "$R" HEAD && bad "N4 a plan-only edit with no rename must be refused" || ok

# ── N5: a nested plan path is not a plan ──
seed "$T/p2.md"
mkdir -p "$R/${PLAN%/*}/sub"; cp "$T/p2.md" "$R/${PLAN%/*}/sub/plan.md"; commit nested
g mv "$SD/$OLD" "$SD/$NEW"
sed -i "s#<UTC-minute>-bh-6889#${NEW%%-*}-bh-6889#" "$R/${PLAN%/*}/sub/plan.md"; g add -A; g commit -qm x
sr_commit_only "$R" HEAD && bad "N5 the plan rule must not apply to .harness/specs/<k>/sub/plan.md" || ok

# ── P6: what the placeholder rule leaves alone ──
cat > "$T/p6.md" <<EOF
## Files to touch
- \`$SD/$OLD\`
- $SD/<stamp>-bh-6889-other.sql
- worker/other/schema.d/<stamp>-bh-6889-alert-lines.sql
- <stamp>-bh-6889-alert-lines.sql
- $SD/2026101606-bh-6889-alert-lines.sql
- $SD/<a b>-bh-6889-alert-lines.sql
- $SD/<x/y>-bh-6889-alert-lines.sql
- $SD/<stamp>-bh-6889-alert-lines.sqlx
EOF
seed "$T/p6.md"
mkdir -p "$R/${PLAN%/*}/sub" "$R/docs"
cp "$T/p2.md" "$R/${PLAN%/*}/sub/plan.md"; printf 'see %s/<stamp>-bh-6889-alert-lines.sql\n' "$SD" > "$R/docs/x.md"; commit more
sr_apply "$R" main >/dev/null; rc=$?
want=$(sed "s#$OLD#$NEW#" "$T/p6.md")
[ "$rc" = 0 ] && [ "$(cat "$R/$PLAN")" = "$want" ] && ok || bad "P6 only the exact old name may change in this plan (rc $rc): $(diff <(printf '%s\n' "$want") "$R/$PLAN")"
cmp -s "$T/p2.md" "$R/${PLAN%/*}/sub/plan.md" && ok || bad "P6 a nested plan.md must keep its placeholders"
grep -qF '<stamp>' "$R/docs/x.md" && ok || bad "P6 a docs file must keep its placeholder"
sr_commit_only "$R" HEAD && ok || bad "P6 the restamp commit must still be accepted"

# ── P7: the PR body's reason line ──
seed "$T/p1.md"
splan=$(sr_plan "$R" main HEAD)
cat > "$T/body.md" <<EOF
## Why
x

## Files outside the plan
- \`$SD/$OLD\`: changed in this build
EOF
cp "$T/body.md" "$T/body0.md"
sr_text_rewrite "$splan" "$T/body.md"; rc=$?
want=$(sed "s#$OLD#$NEW#" "$T/body0.md")
[ "$rc" = 0 ] && [ "$(cat "$T/body.md")" = "$want" ] && ok || bad "P7 sr_text_rewrite rc=$rc: $(cat "$T/body.md")"
sr_text_rewrite "$splan" "$T/body.md"; rc=$?
[ "$rc" = 1 ] && ok || bad "P7 a second sr_text_rewrite must be rc 1 (unchanged), got $rc"
sr_text_rewrite "" "$T/body.md"; rc=$?
[ "$rc" = 2 ] && ok || bad "P7 an empty plan must be rc 2, got $rc"
sr_text_rewrite "$splan" "$T/no-such-file"; rc=$?
[ "$rc" = 2 ] && ok || bad "P7 a missing file must be rc 2, got $rc"

# ── P8: two fragments, each placeholder to its own new name ──
cat > "$T/p8.md" <<EOF
## Files to touch
- $SD/<stamp>-bh-6889-alert-lines.sql
- $SD/<stamp>-bh-6889-alert-seen.sql
EOF
seed "$T/p8.md" "$OLD" 202610160228-bh-6889-alert-seen.sql
sr_apply "$R" main >/dev/null; rc=$?
want="## Files to touch
- $SD/$NEW
- $SD/202610160645-bh-6889-alert-seen.sql"
[ "$rc" = 0 ] && [ "$(cat "$R/$PLAN")" = "$want" ] && ok || bad "P8 two fragments (rc $rc): $(cat "$R/$PLAN")"
sr_commit_only "$R" HEAD && ok || bad "P8 the restamp commit must be accepted"

# ── P9: a broken python3 fails the restamp, HEAD unchanged ──
seed "$T/p2.md"
mkdir -p "$T/badbin"; printf '#!/bin/sh\nexit 3\n' > "$T/badbin/python3"; chmod +x "$T/badbin/python3"
PATH="$T/badbin:$PATH" sr_apply "$R" main >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && [ "$(g rev-parse HEAD)" = "$PRE" ] && ok || bad "P9 a broken python3: rc=$rc, HEAD moved=$([ "$(g rev-parse HEAD)" = "$PRE" ] && echo no || echo yes)"

echo "schema-restamp-plan: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
