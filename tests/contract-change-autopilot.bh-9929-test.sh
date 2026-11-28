#!/bin/bash
# tests/contract-change-autopilot.bh-9929-test.sh — BH-9929 T11: bin/migration-
# autopilot.sh applies a classifier-FLAGGED migration ONLY as an approved step
# of the contract-change lane, and records who approved it.
#   P1  approved contract step (switch on, label contract-step:contract, worker
#       row with backup_ref + restore_ref, human MERGE on the head) -> exactly
#       1 apply POST, actor `contract-change:<approver>`, ledger line
#       `approved_by=<approver>`, the step row POSTed back with verdict + approver
#   P2  the same SQL from an ordinary PR (no labels)   -> 0 POST, ledger `flagged`
#   P3  contract step, row with no backup_ref           -> 0 POST, ledger `flagged`
#   P4  switch off                                       -> 0 POST, ledger `flagged`
#   P5  more pieces missing, each -> 0 POST, `flagged`: no restore_ref; no row;
#       a row for another PR; two step labels; a body step that differs from
#       the label; the PR read fails. Only the verdict missing (a lead MERGE on
#       a human-class step, a human MERGE on an older head, a BLOCK, no
#       verdict) -> 0 POST, `contract-pending` (asked again next tick)
#   P6  a FLAGGED file on an expand or migrate step parks: a DROP TABLE under
#       the label contract-step:migrate (or expand) with a lead MERGE and no
#       backup is never applied (BH-9929 review)
#   P7  the status re-read omits the file -> FAIL, no `applied` ledger line
#   P8  an appliable (not FLAGGED) file keeps actor `autopilot`
#   P9  the approver judges the FILE, not the PR marker:
#       a  contract label, no human marker, DROP TABLE, lead MERGE -> pending,
#          0 POST
#       b  contract label, no human marker, DROP COLUMN, lead MERGE -> pending,
#          0 POST
#       c  a constraint drop with a lead MERGE applies (Scope 4: the normal
#          review only; the same rule as the merge), as
#          contract-change:<reviewer>; with a human MERGE too. A type change
#          (also `TYPE integer USING NULL`) with a lead MERGE -> pending; with
#          a human MERGE it applies
#       d  a constraint drop plus DELETE FROM -> parks (also TRUNCATE, GRANT
#          to anon, UPDATE), even with a human MERGE
#       e  a rider ACTION in the contract statement (DISABLE ROW LEVEL
#          SECURITY, OWNER TO anon) parks with a human MERGE; a DROP COLUMN
#          behind a quoted ')' or '(' stays pending with a lead MERGE
#   P10 the re-ask: a `contract-pending PR#5` ledger row is read again; with
#       the human MERGE now on the head it applies; with no verdict yet it
#       writes nothing and posts nothing; a `flagged` row is never re-read
# The real script runs as a script; gh, curl, the jobs client (ledger, worker
# GET/POST, GitHub REST, the verdict reader) and cc_enabled are fixtures.
# 0 network: the fake curl answers only the app and records every call.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/contract-change-autopilot.bh-9929-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

command -v jq  >/dev/null 2>&1 || { echo "FAIL: jq required by this test";  exit 1; }
command -v git >/dev/null 2>&1 || { echo "FAIL: git required by this test"; exit 1; }

ID="ccap-$$"
HEADSHA=cccccccc33333333333333333333333333333333
OLDSHA=dddddddd44444444444444444444444444444444
mkdir -p "$T/bin/lib" "$T/logs" "$T/state" "$T/flags" "$T/env" "$T/fakebin" "$T/calls" "$T/repo"
cp "$DIR/bin/migration-autopilot.sh" "$DIR/bin/check-migration-appliable.sh" "$T/bin/"
# scratch-closure-allow: the autopilot runs from a scratch bin/ with stub libs beside these real ones; the closure would copy the real stubs over
cp "$DIR/bin/lib/env-path.sh" "$DIR/bin/lib/gh-pr-list.sh" "$DIR/bin/lib/alert-state.sh" \
   "$DIR/bin/lib/contract-change-authority.sh" "$DIR/bin/lib/contract-change-record.sh" "$T/bin/lib/"
# The real classifier lib (cc_classify_sql, cc_residue_sql, cc_human_class),
# with the switch replaced: cc_enabled reads $T/switch (1 = on). The real one
# reads the settings row through lane-gate.sh; tests/contract-change-lib.bh-9929-test.sh pins it.
cp "$DIR/bin/lib/contract-change.sh" "$T/bin/lib/contract-change-real.sh"
cat > "$T/bin/lib/contract-change.sh" <<EOF
#!/bin/bash
. "$T/bin/lib/contract-change-real.sh"
cc_enabled() { [ "\$(cat "$T/switch" 2>/dev/null)" = 1 ]; }
EOF

# ---- the repo: one merged PR that adds a DROP TABLE file --------------------
git -C "$T/repo" init -q -b main
git -C "$T/repo" config user.email t@t.invalid
git -C "$T/repo" config user.name  tester
echo readme > "$T/repo/README.md"
git -C "$T/repo" add -A && git -C "$T/repo" commit -q -m init
mkdir -p "$T/repo/scripts/migrations"
printf 'DROP TABLE report_choice_%s;\n' "${ID//-/_}" > "$T/repo/scripts/migrations/0002_drop.sql"
git -C "$T/repo" add -A && git -C "$T/repo" commit -q -m "add 0002_drop.sql"
MC=$(git -C "$T/repo" rev-parse HEAD)

cat > "$T/env/global.env" <<'EOF'
HARNESS_SECRET=fixture-secret
JOBS_URL=http://jobs.invalid
EOF
cat > "$T/env/project-3.env" <<'EOF'
PROJECT_3_APP_BASE=http://app.test
PROJECT_3_INTERNAL_API_TOKEN=fixture-internal
MIGRATION_TOKEN=fixture-migration
EOF

cat > "$T/bin/fleet-conf.sh" <<'EOF'
#!/bin/bash
[ "${2:-}" = repo ] && echo "o/repo"
exit 0
EOF
# The classifier is the real bin/check-migration-appliable.sh (copied above).
cat > "$T/bin/beat.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/calls/beat"
exit 0
EOF
cat > "$T/bin/lane-alert.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/calls/lane-alert"
exit 0
EOF
chmod +x "$T/bin/fleet-conf.sh" "$T/bin/beat.sh" "$T/bin/lane-alert.sh"

# gh: one merged migration PR (#5, merge commit = the repo HEAD). Any other gh
# call is recorded: the step reads go through gh_rest, never the CLI.
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
case "\$*" in
  *"--limit 100"*)
    jq -nc --arg oid "\$(git -C "$T/repo" rev-parse HEAD)" --arg f "\$(cat "$T/pr-file")" \
      '[{number:5,author:{login:"operator"},mergeCommit:{oid:\$oid},files:[{path:\$f}]}]'
    ;;
  *) printf '%s\n' "\$*" >> "$T/calls/gh-other" ;;
esac
exit 0
EOF
# curl: the app only. Prod serves the merge; the status ledger lists the file
# after an apply POST unless $T/app-never. Every apply body is recorded.
cat > "$T/fakebin/curl" <<EOF
#!/bin/bash
URL=""; BODY=""; prev=""
for a in "\$@"; do
  case "\$a" in http*) URL="\$a" ;; esac
  [ "\$prev" = -d ] && BODY="\$a"
  prev="\$a"
done
case "\$URL" in
  */api/internal/version) printf '{"sha":"%s"}' "\$(git -C "$T/repo" rev-parse HEAD)"; exit 0 ;;
  */api/internal/migrations/status)
    if [ -f "$T/calls/apply-post" ] && [ ! -e "$T/app-never" ]; then
      jq -nc --arg f "\$(basename "\$(cat "$T/pr-file")")" '{applied:[{filename:\$f}]}'
    else printf '{"applied":[]}'; fi
    exit 0 ;;
  */api/internal/migrations/apply)
    printf '%s\n' "\$BODY" >> "$T/calls/apply-post"
    printf '{"ok":true,"status":"applied"}'; exit 0 ;;
esac
printf '%s\n' "\$URL" >> "$T/calls/net"
exit 22
EOF
chmod +x "$T/fakebin/gh" "$T/fakebin/curl"

# The jobs client: the ledger (always absent), the worker's contract-changes
# route ($T/row = the rows answer; POSTs recorded), GitHub REST pulls/<n>
# ($T/labels one per line, $T/body; $T/pr-fail fails the read) and the verdict
# reader ($T/standing = `<verdict> <source> <head> <reviewer>`, head-bound).
cat > "$T/bin/jobs-client.sh" <<EOF
#!/bin/bash
if [ -z "\${HARNESS_SECRET:-}" ] && [ -r "$T/env/global.env" ]; then
  HARNESS_SECRET=\$(sed -n 's/^HARNESS_SECRET=//p' "$T/env/global.env" | head -1)
  [ -n "\$HARNESS_SECRET" ] && export HARNESS_SECRET
fi
job_ledger_get() {
  printf '%s\t%s\n' "\$1" "\$2" >> "$T/calls/ledger-get"
  [ -s "$T/ledger-status" ] || return 2
  cat "$T/ledger-status"; return 0
}
job_ledger_put() { printf '%s\t%s\t%s\n' "\$1" "\$2" "\${3:-}" >> "$T/calls/ledger-put"; return 0; }
_jobs_req() {
  printf '%s %s\n' "\$1" "\$2" >> "$T/calls/jobs"
  case "\$1 \$2" in
    "GET /api/contract-changes?"*) [ -f "$T/row" ] || { printf '{"rows":[]}'; return 0; }; jq -c '{rows:[.]}' "$T/row" ;;
    "POST /api/contract-changes") printf '%s\n' "\$3" >> "$T/calls/cc-post"; printf '{"row":{"id":1}}' ;;
    *) return 1 ;;
  esac
}
gh_rest() {
  printf '%s %s\n' "\$1" "\$2" >> "$T/calls/rest"
  case "\$2" in
    repos/o/repo/pulls/5)
      [ -e "$T/pr-fail" ] && return 75
      jq -nc --arg h "$HEADSHA" --rawfile l "$T/labels" --rawfile b "$T/body" \
        '{number:5, head:{sha:\$h}, body:\$b, labels:(\$l | split("\n") | map(select(length > 0)) | map({name:.}))}' ;;
    *) return 75 ;;
  esac
}
vd_standing() {
  local v s h r
  [ -f "$T/standing" ] || return 1
  read -r v s h r < "$T/standing"
  [ "\$h" = "\$3" ] || return 1
  printf '%s\t%s\t7\t2026-11-24T00:00:00Z\t-\t%s\n' "\$v" "\$s" "\${r:--}"
}
EOF

# ---- helpers ----------------------------------------------------------------
reset() {
  rm -rf "$T/calls" "$T/logs" "$T/state" "$T/locks"
  mkdir -p "$T/calls" "$T/logs" "$T/state" "$T/locks"
  : > "$T/calls/ledger-put"; : > "$T/calls/jobs"
  for f in row standing app-never pr-fail ledger-status; do [ ! -e "$T/$f" ] || rm -f "$T/$f"; done
  printf 'scripts/migrations/0002_drop.sql' > "$T/pr-file"
  printf 1 > "$T/switch"
  printf 'contract-step:contract\ncontract-change:human\n' > "$T/labels"
  printf 'CONTRACT STEP: contract of #41\nCONTRACT-HUMAN-VERDICT: required\n' > "$T/body"
  row contract 'branch project-3-pre-9929' 'turso db shell scratch < dump.sql' 5
  printf 'MERGE human %s operator\n' "$HEADSHA" > "$T/standing"
}
# row <step> <backup_ref> <restore_ref> <pr#>
row() {
  jq -nc --arg s "$1" --arg b "$2" --arg r "$3" --arg u "https://github.com/o/repo/pull/$4" --arg h "$HEADSHA" \
    '{project:"project-3", parent_ticket:41, step:$s, pr_url:$u, head_sha:$h, classes:"drop-table",
      backup_ref:$b, restore_ref:$r, verdict:null, approved_by:null}' > "$T/row"
}
run_autopilot() {
  HARNESS="$T" MIGRATION_AUTOPILOT_REPO_DIR="$T/repo" PATH="$T/fakebin:$PATH" \
    bash "$T/bin/migration-autopilot.sh" project-3 >/dev/null 2>&1
}
posts() { if [ -f "$T/calls/apply-post" ]; then wc -l < "$T/calls/apply-post"; else echo 0; fi; }
ccposts() { if [ -f "$T/calls/cc-post" ]; then wc -l < "$T/calls/cc-post"; else echo 0; fi; }
puts_line() { cut -f3 "$T/calls/ledger-put" | tr '\n' '|'; }
# parked <case> — 0 apply POST, one `flagged PR#5` ledger line, no cc POST.
parked() {
  local rc=0
  run_autopilot || rc=$?
  [ "$rc" = 0 ] && [ "$(posts)" = 0 ] && [ "$(puts_line)" = "flagged PR#5|" ] && [ "$(ccposts)" = 0 ] && ok \
    || bad "$1: want rc 0, 0 apply POST, ledger 'flagged PR#5' (rc $rc, $(posts) POST, ledger '$(puts_line)', $(ccposts) cc POST)"
}

# pending <case> — 0 apply POST, one `contract-pending PR#5` ledger line, no
# cc POST: an approvable step whose verdict does not clear it yet is re-asked
# on later ticks, not parked for good (BH-9929 review).
pending() {
  local rc=0
  run_autopilot || rc=$?
  [ "$rc" = 0 ] && [ "$(posts)" = 0 ] && [ "$(puts_line)" = "contract-pending PR#5|" ] && [ "$(ccposts)" = 0 ] && ok \
    || bad "$1: want rc 0, 0 apply POST, ledger 'contract-pending PR#5' (rc $rc, $(posts) POST, ledger '$(puts_line)', $(ccposts) cc POST)"
}

# ===========================================================================
# P1. An approved contract step applies once, as contract-change:operator.
# ===========================================================================
reset
run_autopilot; RC=$?
[ "$RC" = 0 ] && ok || bad "P1: rc=$RC ($(cat "$T/logs/project-3.log" 2>/dev/null))"
[ "$(posts)" = 1 ] && ok || bad "P1: want exactly 1 apply POST, got $(posts)"
[ "$(jq -r '.actor' "$T/calls/apply-post" 2>/dev/null)" = "contract-change:operator" ] && ok \
  || bad "P1: actor want contract-change:operator: $(cat "$T/calls/apply-post" 2>/dev/null)"
[ "$(jq -r '.filename' "$T/calls/apply-post" 2>/dev/null)" = "0002_drop.sql" ] && ok || bad "P1: the POST names the file"
[ "$(puts_line)" = "applied PR#5 serving=${MC:0:8} approved_by=operator|" ] && ok || bad "P1: ledger line: '$(puts_line)'"
[ "$(ccposts)" = 1 ] && jq -e '.project == "project-3" and .parent_ticket == 41 and .step == "contract"
    and .verdict == "MERGE" and .approved_by == "operator"' "$T/calls/cc-post" >/dev/null 2>&1 && ok \
  || bad "P1: the step row POST carries verdict + approved_by: $(cat "$T/calls/cc-post" 2>/dev/null)"
grep -qF 'GET /api/contract-changes?project=project-3&parent_ticket=41&step=contract' "$T/calls/jobs" && ok \
  || bad "P1: the worker row is read by (project, parent, step): $(cat "$T/calls/jobs")"
[ ! -s "$T/calls/net" ] && [ ! -s "$T/calls/gh-other" ] && ok \
  || bad "P1: 0 network and no gh CLI read: $(cat "$T/calls/net" "$T/calls/gh-other" 2>/dev/null)"

# ===========================================================================
# P2-P4. The ticket's three refusals.
# ===========================================================================
reset; : > "$T/labels"; : > "$T/body"
parked "P2 the same SQL from an ordinary PR"
grep -q 'classifier-FLAGGED — keeping the page-a-human path' "$T/logs/project-3.log" && ok || bad "P2: the parked log line is today's"
reset; row contract '' 'turso db shell scratch < dump.sql' 5
parked "P3 contract step with no backup_ref"
reset; printf 0 > "$T/switch"
parked "P4 switch off"
[ ! -s "$T/calls/jobs" ] && ok || bad "P4: switch off reads no worker row: $(cat "$T/calls/jobs")"

# ===========================================================================
# P5. Every other missing piece parks.
# ===========================================================================
reset; row contract 'branch project-3-pre-9929' '' 5;               parked "P5 no restore_ref"
reset; rm -f "$T/row";                                          parked "P5 no worker row"
reset; row contract 'branch project-3-pre-9929' 'restore cmd' 9;     parked "P5 a row for another PR"
reset; printf 'MERGE lead %s claude\n' "$HEADSHA" > "$T/standing"; pending "P5 a lead MERGE on a human-class step"
reset; printf 'contract-step:contract\n' > "$T/labels"; printf 'MERGE lead %s claude\n' "$HEADSHA" > "$T/standing"
printf 'CONTRACT STEP: contract of #41\nCONTRACT-HUMAN-VERDICT: required\n' > "$T/body"; pending "P5 a lead MERGE when only the body line asks for a human"
reset; printf 'MERGE human %s operator\n' "$OLDSHA" > "$T/standing"; pending "P5 a human MERGE on an older head"
reset; printf 'BLOCK human %s operator\n' "$HEADSHA" > "$T/standing";  pending "P5 a BLOCK"
reset; rm -f "$T/standing";                                       pending "P5 no verdict"
reset; printf 'contract-step:contract\ncontract-step:migrate\ncontract-change:human\n' > "$T/labels"; parked "P5 two step labels"
reset; printf 'CONTRACT STEP: migrate of #41\n' > "$T/body";      parked "P5 the body names another step"
reset; touch "$T/pr-fail";                                        parked "P5 the PR read fails"

# ===========================================================================
# P6. A FLAGGED file on an expand or migrate step never applies. The gate keeps
# those steps additive, so a DROP TABLE there came from outside the lane's
# rules (a later fix round, a hand label). A lead and a human MERGE both park.
# ===========================================================================
reset; printf 'contract-step:migrate\n' > "$T/labels"; printf 'CONTRACT STEP: migrate of #41\n' > "$T/body"
row migrate '' '' 5; printf 'MERGE-WITH-NOTES lead %s\n' "$HEADSHA" > "$T/standing"
parked "P6 migrate label + DROP TABLE + lead MERGE"
reset; printf 'contract-step:migrate\n' > "$T/labels"; printf 'CONTRACT STEP: migrate of #41\n' > "$T/body"
row migrate 'branch project-3-pre-9929' 'restore cmd' 5
parked "P6 migrate label + DROP TABLE + human MERGE + a backup row"
reset; printf 'contract-step:expand\n' > "$T/labels"; printf 'CONTRACT STEP: expand of #41\n' > "$T/body"
row expand '' '' 5; printf 'MERGE lead %s claude\n' "$HEADSHA" > "$T/standing"
parked "P6 expand label + DROP TABLE + lead MERGE"

# ===========================================================================
# P7. The status re-read omits the file: FAIL, never an `applied` line.
# ===========================================================================
reset; touch "$T/app-never"
run_autopilot; RC=$?
[ "$RC" = 1 ] && [ "$(posts)" = 1 ] && ! grep -q 'applied' <<<"$(puts_line)" && grep -q '^failed-alerted PR#5' <<<"$(puts_line)" && [ "$(ccposts)" = 0 ] && ok \
  || bad "P7: want rc 1, ledger failed-alerted, no applied line, no row POST (rc $RC, '$(puts_line)', $(ccposts))"

# ===========================================================================
# P8. An appliable file keeps actor autopilot and today's ledger line.
# ===========================================================================
reset
printf 'ALTER TABLE t ADD COLUMN c text;\n' > "$T/repo/scripts/migrations/0003_add.sql"
git -C "$T/repo" add -A && git -C "$T/repo" commit -q -m "add 0003_add.sql"
printf 'scripts/migrations/0003_add.sql' > "$T/pr-file"
MC2=$(git -C "$T/repo" rev-parse HEAD)
run_autopilot
[ "$(posts)" = 1 ] && [ "$(jq -r '.actor' "$T/calls/apply-post")" = autopilot ] && [ "$(puts_line)" = "applied PR#5 serving=${MC2:0:8}|" ] \
  && [ ! -s "$T/calls/jobs" ] && ok \
  || bad "P8: an appliable file: actor autopilot, today's ledger line, no worker read ($(cat "$T/calls/apply-post" 2>/dev/null), '$(puts_line)')"

# ===========================================================================
# P9. The approver judges the file it applies, not the marker pr.sh wrote when
# the PR opened. Each case commits its own file (the newest commit is the merge).
# ===========================================================================
# use_sql <name> <sql> — commit scripts/migrations/<name> as the merged PR's file.
use_sql() {
  printf '%s\n' "$2" > "$T/repo/scripts/migrations/$1"
  git -C "$T/repo" add -A && git -C "$T/repo" commit -q -m "add $1"
  printf 'scripts/migrations/%s' "$1" > "$T/pr-file"
}
# no_marker — a contract step PR with no human label and no human body line.
no_marker() {
  printf 'contract-step:contract\n' > "$T/labels"; printf 'CONTRACT STEP: contract of #41\n' > "$T/body"
  printf 'MERGE lead %s claude\n' "$HEADSHA" > "$T/standing"
}
reset; use_sql 0101_drop.sql "DROP TABLE report_old_${ID//-/_};"; no_marker
pending "P9a contract label, no human marker, DROP TABLE, lead MERGE"
reset; use_sql 0102_dropcol.sql "ALTER TABLE report_choice DROP COLUMN kind_${ID//-/_};"; no_marker
pending "P9b contract label, no human marker, DROP COLUMN, lead MERGE"
# Scope 4: a constraint step needs the normal review only, at the
# merge (cc_la_gate) AND at the apply, so a step the lane may merge is a step
# it applies (BH-9929 review: it merged and then parked for good).
# applied_by <case> <who> — exactly 1 apply POST as contract-change:<who>, the
# step row POSTed with verdict MERGE and approved_by <who>.
applied_by() {
  run_autopilot
  [ "$(posts)" = 1 ] && [ "$(jq -r '.actor' "$T/calls/apply-post")" = "contract-change:$2" ] && ok \
    || bad "$1: want 1 POST as contract-change:$2 ($(posts) POST: $(cat "$T/calls/apply-post" 2>/dev/null), log: $(tail -2 "$T/logs/project-3.log" 2>/dev/null))"
  jq -e --arg w "$2" '.verdict == "MERGE" and .step == "contract" and .approved_by == $w' "$T/calls/cc-post" >/dev/null 2>&1 && ok \
    || bad "$1: row POST $(cat "$T/calls/cc-post" 2>/dev/null)"
}
reset; use_sql 0103_constraint.sql "ALTER TABLE report_choice DROP CONSTRAINT report_choice_kind_check_${ID//-/_};"; no_marker
applied_by "P9c a constraint drop with a lead MERGE" claude
# A type change is a human class (BH-9929 refute review): a cast can lose
# every stored value as a drop does. A lead MERGE keeps it pending; a human
# MERGE applies it.
reset; use_sql 0103_type.sql "ALTER TABLE report_choice ALTER COLUMN kind_${ID//-/_} TYPE integer USING kind_${ID//-/_}::integer;"; no_marker
pending "P9c a type change with a lead MERGE"
reset; use_sql 0103_type_null.sql "ALTER TABLE invoices ALTER COLUMN amount_${ID//-/_} TYPE integer USING NULL;"; no_marker
pending "P9c a lossy 'TYPE integer USING NULL' with a lead MERGE"
reset; use_sql 0103_type_h.sql "ALTER TABLE report_choice ALTER COLUMN kind_h_${ID//-/_} TYPE integer USING kind_h_${ID//-/_}::integer;"; no_marker
printf 'MERGE human %s operator\n' "$HEADSHA" > "$T/standing"
applied_by "P9c a type change with a human MERGE" operator
reset; use_sql 0103_constraint_h.sql "ALTER TABLE report_choice DROP CONSTRAINT report_choice_kind_check_h_${ID//-/_};"; no_marker
printf 'MERGE human %s operator\n' "$HEADSHA" > "$T/standing"
run_autopilot
[ "$(posts)" = 1 ] && [ "$(jq -r '.actor' "$T/calls/apply-post")" = "contract-change:operator" ] && ok \
  || bad "P9c: a constraint drop with a human MERGE applies ($(posts) POST: $(cat "$T/calls/apply-post" 2>/dev/null), log: $(tail -2 "$T/logs/project-3.log" 2>/dev/null))"
jq -e '.verdict == "MERGE" and .step == "contract" and .approved_by == "operator"' "$T/calls/cc-post" >/dev/null 2>&1 && ok \
  || bad "P9c: row POST $(cat "$T/calls/cc-post" 2>/dev/null)"
for rider in "DELETE FROM users" "TRUNCATE invoices" "GRANT ALL ON users TO anon" "UPDATE users SET role = 'admin'"; do
  reset
  use_sql "0104_rider_$(printf '%s' "$rider" | cut -d' ' -f1 | tr 'A-Z' 'a-z').sql" \
    "ALTER TABLE orders DROP CONSTRAINT orders_status_check_${ID//-/_}; $rider;"
  parked "P9d a constraint drop plus '$rider', human MERGE"
done

# P9e. A rider ACTION inside the contract ALTER TABLE parks, even with a human
# MERGE (BH-9929 review). A drop hidden behind a quoted ')' is a drop-column,
# so a lead MERGE parks it.
n=0
for st in "ALTER TABLE report_choice ALTER COLUMN tier TYPE text, DISABLE ROW LEVEL SECURITY;" \
          "ALTER TABLE report_choice DROP CONSTRAINT c1_${ID//-/_}, NO FORCE ROW LEVEL SECURITY, OWNER TO anon;" \
          "ALTER TYPE status_${ID//-/_} OWNER TO anon;"; do
  n=$((n+1)); reset; use_sql "0105_rider_action_$n.sql" "$st"
  parked "P9e a rider action, human MERGE: $st"
done
reset; use_sql 0106_hidden.sql "ALTER TABLE orders DROP CONSTRAINT o_${ID//-/_}, ADD CONSTRAINT o_${ID//-/_} CHECK (note NOT LIKE '%:)'), DROP COLUMN legacy_status;"; no_marker
pending "P9e a DROP COLUMN behind a quoted ')', lead MERGE"
reset; use_sql 0107_hidden.sql "ALTER TABLE t DROP CONSTRAINT \"a(b_${ID//-/_}\", DROP COLUMN secret;"; no_marker
pending "P9e a DROP COLUMN behind a quoted '(' name, lead MERGE"

# ===========================================================================
# P10. The re-ask. A verdict posted after the merge is read on a later tick.
# ===========================================================================
reset; use_sql 0108_drop.sql "DROP TABLE report_old_p10_${ID//-/_};"; MC10=$(git -C "$T/repo" rev-parse HEAD)
printf 'contract-pending PR#5' > "$T/ledger-status"
run_autopilot
[ "$(posts)" = 1 ] && [ "$(jq -r '.actor' "$T/calls/apply-post")" = "contract-change:operator" ] \
  && [ "$(puts_line)" = "applied PR#5 serving=${MC10:0:8} approved_by=operator|" ] && ok \
  || bad "P10: a contract-pending row with the human MERGE now on the head applies ($(posts) POST, ledger '$(puts_line)')"
reset; printf 'contract-pending PR#5' > "$T/ledger-status"; rm -f "$T/standing"
run_autopilot
[ "$(posts)" = 0 ] && [ ! -s "$T/calls/ledger-put" ] && [ "$(ccposts)" = 0 ] && ok \
  || bad "P10: still no verdict: 0 POST and no second ledger write ($(posts) POST, ledger '$(puts_line)')"
reset; printf 'flagged PR#5' > "$T/ledger-status"
run_autopilot
[ "$(posts)" = 0 ] && [ ! -s "$T/calls/ledger-put" ] && [ ! -s "$T/calls/rest" ] && ok \
  || bad "P10: a flagged row is final: 0 POST, no ledger write, no PR read ($(posts) POST, ledger '$(puts_line)')"

echo "contract-change-autopilot: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
