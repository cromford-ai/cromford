#!/bin/bash
# tests/slice-closeout-columns.bh-9622-test.sh — BH-9622: the slice close-out
# reads the requirement and Task columns from each table's header row.
#
# WHAT HAPPENED. The BH-9580 plan's coverage table starts
# `| # | Ticket words | Task | File | Test |`. _sco_rows read cell 2 (`#`) as the
# requirement and cell 3 (the ticket words) as the Task cell, so all 24 rows
# were undecided and the close-out filed #9622 with the items `1` to `24`.
#
# WHAT THIS PINS:
#   C1     the real BH-9580 table: one undecided row, by its text, no bare numbers
#   C2     a `#`-first table: the uncovered row is named by its text
#   C3-C5  old shapes keep their result (Requirement|Task, Delivered by, no Task header)
#   C4b    `| # | ticket words | delivered by | test |`
#   C6     `| req | ticket text | task | test |`
#   C7     a `###` sub-table uses its own header
#   C8     an exclusion row in a `#`-first table stays excluded (BH-8329)
#   C9     a short row is skipped; mawk runs the same pass
#   C10    the Test cell of a `#`-first table is still read for deferral words
#   C11    the requirement cell is never read as a deferral ("remaining")
#   B1     0 GitHub calls: a gh stub logs and exits 99
#
#   HARNESS_TEST_SANDBOX=1 bash tests/slice-closeout-columns.bh-9622-test.sh   exit 0 = pass
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

mkdir -p "$T/fakebin"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/gh.log"\nexit 99\n' "$T" > "$T/fakebin/gh"
chmod +x "$T/fakebin/gh"
export PATH="$T/fakebin:$PATH"
unset SLICE_CLOSEOUT_EXCLUDE_HEADINGS
# shellcheck source=bin/lib/slice-closeout.sh
. "$DIR/bin/lib/slice-closeout.sh" || { echo "FAIL: cannot source slice-closeout.sh"; exit 1; }

# plan <name> — write stdin as a plan with a coverage section; print its path.
plan() { { printf '# plan\n\n## Requirements coverage\n\n'; cat; printf '\n## Acceptance tests\n\n- x\n'; } > "$T/$1.md"; printf '%s' "$T/$1.md"; }
# eq <id> <got> <want>
eq() { if [ "$2" = "$3" ]; then ok; else bad "$1: got [$2] want [$3]"; fi; }

# --- C1: the real BH-9580 table (origin/main .harness/specs/BH-9580/plan.md) -
p=$(plan c1 <<'MD'
| # | Ticket words | Task | File | Test |
|---|---|---|---|---|
| 1 | "Schema fragment … Columns, unique key and the 4 indexes exactly as the CONTRACT line says" | T1 | `worker/jobs/schema.d/202611121730-bh-9559-human-gates.sql` | worker C1, C5 |
| 2 | "Seed the gate class rows: irreversible for migration-gated, hotfix-migration-hold, provenance, security-allowlist; defaultable for plan_blocked … parked" | T1 | same | worker C3 |
| 3 | "Seed the knob rows and the 4 kill flags (default 1)" (`deadline_hours=24`, `hold_review_days=7`, `digest_hour_utc=7`, `retention_days=90`) | T1 | same | worker C8 (seed values read back) |
| 4 | "Each CREATE TABLE has its CREATE INDEX in the same diff" | T1 | same | `bin/rules-pack.sh` index-on-create-table |
| 5 | "POST /api/human-gates upserts by (repo,key,lane,question_fp); a re-ask is an upsert, never a second row" | T2 | `worker/jobs/src/routes/human-gates.js` | worker C1 |
| 6 | "A body with no default_answer or no recommended is 400" | T2 | same | worker C2 |
| 7 | "deadline_at is computed server side from human_gate.deadline_hours when absent" | T2 | same | worker C7 |
| 8 | "an unknown reason is irreversible (fail-closed, also Migration-Gated, migration-gated-v2, empty)" | T2, T4 | `human-gates.js`, `bin/lib/human-gate.sh` | worker C3, shell F6 |
| 9 | "never an edit to index.js" (route-table fragment) | T2 | `worker/jobs/test/route-table.d/bh-9559-human-gates.txt` | worker C1 runs through real `worker.fetch` |
| 10 | "rows with status != open older than human_gate.retention_days move to human_gates_archive" | T3 | `retention.d/bh-9559-human-gates.js` | worker C6 |
| 11 | "hg_ask refuses (rc 2, one stderr line, no POST) a call with no default, no recommended answer, or 0 or more than 3 reasons" | T4 | `bin/lib/human-gate.sh` | shell F2, F3, F4 |
| 12 | "On success it prints the 5-field block: Question, Recommended answer, Reasons (1-3), Default, Deadline (UTC)" | T4 | same | shell F1 |
| 13 | "Kill flag human_gate.format.enabled=0: hg_ask prints nothing and returns 0" | T4 | same | shell F5 |
| 14 | "hg_release … calls hgr_<lane>; a lane file that defines no hgr_<lane> is rc 3 with one log line" | T4, T7 | same + `human-gate-release.d/conductor.sh` | shell F8 |
| 15 | "hgr_plan requeues the ticket through bin/queue-line-put.sh with the answer recorded" | T5 | `bin/lib/human-gate-release.d/plan.sh` | shell F7 |
| 16 | "Wire the planner block … through hg_ask … the existing page and reminder stay. Lane plan, reason plan_blocked" | T6 | `bin/lib/rb/plan.sh`, `bin/lib/plan-blocked.sh` | shell F1; `tests/plan-blocked-marker-test.sh`, `tests/plan-blocked-notice.bh-7116-test.sh` stay green |
| 17 | "conductor.sh, tackler.sh, needs-human.sh each a 2-line file with the comment # owner: BH-9559.2 and no function" | T7 | `bin/lib/human-gate-release.d/*.sh` | shell F8 (+ line count check in F9) |
| 18 | "The 6 stub docs … each one heading plus owner: BH-9559.<n>" | T7 | `docs/human-gates/*.md`, `docs/gates/*.md` | shell F9 (files exist, owner line) |
| 19 | "docs/CUSTODY.md with a ## Human gates section … links the 4 docs/human-gates/*.md stubs" | T8 | `docs/CUSTODY.md` | shell F9 (4 links resolve) |
| 20 | "one ## Human gates paragraph to docs/GATES-VS-REPORTS.md … links prequeue-fresh-main.md and builder-topred.md" | T8 | `docs/GATES-VS-REPORTS.md` | shell F9 |
| 21 | "one line to docs/MERGE-CONDUCTOR.md that links docs/human-gates/conductor.md" | T8 | `docs/MERGE-CONDUCTOR.md` | shell F9 |
| 22 | Observable outcome: "one human_gates row with lane=plan, gate_class=defaultable, status=open and a non-null deadline_at" | T4, T6 | `bin/lib/human-gate.sh`, `rb/plan.sh` | shell F1 (fake D1 row) |
| 23 | "No vendor calls: gh is a PATH fake that fails on any unknown call" | test | `tests/human-gate-format.bh-9559-test.sh` | F1-F9 (fake `gh` exits 99 and logs) |
| 24 | "EXPLAIN QUERY PLAN on seeded rows uses each of the 4 indexes" | T1 | schema fragment | worker C5 |
MD
)
out=$(sco_coverage "$p" 0)
eq C1.head "$(head -1 <<<"$out")" "$(printf 'undecided\trows:1')"
eq C1.lines "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" 2
case "$(printf '%s\n' "$out" | sed -n 2p)" in '"No vendor calls'*) ok ;; *) bad "C1.row: $(printf '%s\n' "$out" | sed -n 2p)" ;; esac
grep -Eq '^[0-9]+$' <<<"$out" && bad "C1: a bare row number in the output" || ok

# --- C2: `#`-first table, k=1 ---------------------------------------------------
p=$(plan c2 <<'MD'
| # | Requirement (ticket) | Task | Test |
|---|---|---|---|
| 1 | do a | T1 | x |
| 2 | do b | C2 | y |
MD
)
eq C2 "$(sco_coverage "$p" 1)" "$(printf 'uncovered\t1\ndo b')"

# --- C3-C5: the old shapes ---------------------------------------------------------
p=$(plan c3 <<'MD'
| Requirement | Task | Test |
|---|---|---|
| r | T1 | x |
MD
)
eq C3 "$(sco_coverage "$p" 0)" covered
p=$(plan c4 <<'MD'
| Requirement | Delivered by | Test |
|---|---|---|
| r | later slice | x |
MD
)
eq C4 "$(sco_coverage "$p" 0)" "$(printf 'uncovered\t1\nr')"
p=$(plan c5 <<'MD'
| Requirement | Owner | Test |
|---|---|---|
| r | T1 | x |
MD
)
eq C5 "$(sco_coverage "$p" 0)" covered

# C4b: "Delivered by" in a `#`-first table is the Task column.
p=$(plan c4b <<'MD'
| # | ticket words | delivered by | test |
|---|---|---|---|
| 1 | the ask | T2 | x |
| 2 | the other ask | later slice | y |
MD
)
eq C4b "$(sco_coverage "$p" 0)" "$(printf 'uncovered\t1\nthe other ask')"

# --- C6: `| req | ticket text | task | test |` --------------------------------------
p=$(plan c6a <<'MD'
| req | ticket text | task | test |
|---|---|---|---|
| R1 | the fix | T1 | A1 |
MD
)
eq C6.covered "$(sco_coverage "$p" 0)" covered
p=$(plan c6b <<'MD'
| req | ticket text | task | test |
|---|---|---|---|
| R1 | the fix | - | A1 |
MD
)
eq C6.uncovered "$(sco_coverage "$p" 0)" "$(printf 'uncovered\t1\nthe fix')"

# --- C7: a `###` sub-table has its own header ---------------------------------------
p=$(plan c7 <<'MD'
| Requirement | Task | Test |
|---|---|---|
| first ask | T1 | x |

### Part B

| # | Ask | Task |
|---|---|---|
| 1 | second ask | - |
| 2 | third ask | T2 |
MD
)
eq C7 "$(_sco_rows "$p" 0)" "$(printf 'covered\tfirst ask\nuncovered\tsecond ask\ncovered\tthird ask')"

# --- C8: an exclusion row in a `#`-first table (BH-8329) ----------------------------
p=$(plan c8 <<'MD'
| # | Requirement | Task | Test |
|---|---|---|---|
| 3 | Out of scope: the 17 tests | none | - |
MD
)
eq C8.rows "$(_sco_rows "$p" 0)" "$(printf 'excluded\tOut of scope: the 17 tests')"
eq C8 "$(sco_coverage "$p" 0)" covered

# --- C9: a short row is skipped; the same pass under mawk ----------------------------
p=$(plan c9 <<'MD'
| # | Ask | Task |
|---|---|---|
| 4 |
| 5 | real ask | T1 |
MD
)
eq C9 "$(_sco_rows "$p" 0 2>&1)" "$(printf 'covered\treal ask')"
if command -v mawk >/dev/null 2>&1; then
  mkdir -p "$T/mawkbin"; ln -sf "$(command -v mawk)" "$T/mawkbin/awk"
  eq C9.mawk "$(PATH="$T/mawkbin:$PATH" _sco_rows "$p" 0 2>&1)" "$(printf 'covered\treal ask')"
  eq C9.mawk.c1 "$(PATH="$T/mawkbin:$PATH" sco_coverage "$T/c1.md" 0 2>&1 | head -1)" "$(printf 'undecided\trows:1')"
else
  echo "C9: mawk not on PATH, mawk run skipped"
fi

# --- C10: the Test cell of a `#`-first table is still read --------------------------
p=$(plan c10 <<'MD'
| # | Requirement | Task | Test |
|---|---|---|---|
| 1 | r | T1 | child slice C2 |
MD
)
eq C10 "$(sco_coverage "$p" 1)" "$(printf 'uncovered\t1\nr')"

# --- C11: the requirement cell is not read for deferral words --------------------
p=$(plan c11 <<'MD'
| # | Ticket words | Task | Test |
|---|---|---|---|
| 1 | list the remaining items | T1 | x |
MD
)
eq C11 "$(sco_coverage "$p" 0)" covered

# --- B1: no GitHub call ---------------------------------------------------------------
[ -e "$T/gh.log" ] && bad "B1: gh was called: $(head -3 "$T/gh.log")" || ok

echo "slice-closeout-columns: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
