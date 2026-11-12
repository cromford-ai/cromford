#!/bin/bash
# tests/human-gate-format.bh-9559-test.sh — BH-9559 part A (BH-9580 tracer):
# the planner block asks its questions as human gates, and the plan comment
# carries the 5-field block.
#
# The jobs worker is REAL: the real bin/jobs-client.sh talks to a fake curl
# that hands each request to worker/jobs/src/index.js over a file-backed
# node:sqlite DB with the composed jobs schema. So a human_gates row in this
# suite is a row the route wrote. gh is a PATH fake that logs and exits 99.
#
#   F1  planner block: the real `plan blocked gate` of bin/lib/rb/plan.sh ends
#       rc 4 / PLAN_BLOCKED, writes human-gates.md with the 5 fields and one
#       human_gates row (lane plan, plan_blocked, defaultable, open, deadline);
#       pb_notice posts those 5 fields. A re-plan re-asks the same row.
#   F2  no default (no --, blank, two values) -> rc 2, one stderr line, no POST
#   F3  no recommended answer -> rc 2, no POST
#   F4  0, 4 or a blank reason -> rc 2, no POST; 1 and 3 reasons -> rc 0
#   F5  human_gate.format.enabled=0 -> hg_ask prints nothing, rc 0, no POST;
#       the planner block writes no file and no row; pb_notice posts the cq text
#   F6  hg_class: the decision table (unknown, case, near miss, empty, outage)
#   F7  hg_release plan -> bin/queue-line-put.sh gets the key and the answer
#   F8  hg_release conductor (placeholder) -> rc 3; a bad lane -> rc 2
#   F9  the seams and the docs: placeholders, stubs, links
#   F10 the worker is down -> hg_ask rc 1, nothing printed; no human-gates.md
#
# Run from anywhere (exit 0 = pass).
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
done_() { echo "human-gate-format: $PASS passed, $FAIL failed"; [ "$FAIL" = 0 ]; exit $?; }
command -v jq >/dev/null || { echo "human-gate-format: SKIPPED, jq missing"; exit 0; }

SRCS=(
  "$DIR/bin/lib/human-gate.sh"
  "$DIR/bin/jobs-client.d/bh-9580-human-gate-put.sh"
  "$DIR/bin/lib/human-gate-release.d/plan.sh"
  "$DIR/bin/lib/human-gate-release.d/conductor.sh"
  "$DIR/bin/lib/human-gate-release.d/tackler.sh"
  "$DIR/bin/lib/human-gate-release.d/needs-human.sh"
  "$DIR/worker/jobs/src/routes/human-gates.js"
  "$DIR/worker/jobs/src/routes/retention.d/bh-9559-human-gates.js"
  "$DIR/worker/jobs/schema.d/202611121730-bh-9559-human-gates.sql"
  "$DIR/worker/jobs/test/route-table.d/bh-9559-human-gates.txt"
)
for f in "${SRCS[@]}"; do [ -f "$f" ] && ok || bad "missing $f"; done
for f in "${SRCS[@]}"; do case "$f" in *.sh) bash -n "$f" 2>/dev/null && ok || bad "$f does not parse" ;; esac; done
[ -f "$DIR/bin/lib/human-gate.sh" ] || done_

if ! command -v node >/dev/null 2>&1 || ! node -e 'require("node:sqlite")' >/dev/null 2>&1; then
  echo "human-gate-format: SKIPPED, this node has no node:sqlite (CI's worker/jobs job runs the route suite)"
  done_
fi

# The worker imports git-ignored, composed catalogs; compose them before it loads.
HARNESS_TEST_SANDBOX=1 "$DIR/bin/lanes-build.sh" --root "$DIR" --write >"$T/lb.out" 2>&1 \
  || bad "catalog/lanes.json could not be composed: $(cat "$T/lb.out")"
[ -f "$DIR/catalog/llm-sites.json" ] || (cd "$DIR" && bin/llm-sites-build.sh --compose) >"$T/ls.out" 2>&1 || bad "llm-sites: $(cat "$T/ls.out")"
[ -f "$DIR/catalog/context-budgets.json" ] || (cd "$DIR" && bin/context-budgets-build.sh --compose) >"$T/cb.out" 2>&1 || bad "context-budgets: $(cat "$T/cb.out")"

# The route suite, so this shell suite pins the worker side too.
if (cd "$DIR/worker/jobs" && node --test test/human-gates.bh-9559.test.js >"$T/route.out" 2>&1); then ok
else
  bad "worker route suite: $(grep -E 'not ok' "$T/route.out" | head -5)"
  grep -E 'Error|expected|actual' "$T/route.out" | head -30 | sed 's/^/  route: /'
fi

# ── the real worker behind a fake curl ───────────────────────────────────────
export HG_T="$T" HG_DB="$T/d1.sqlite" NODE_OPTIONS=--no-warnings
cat >"$T/init.mjs" <<EOF
import { readFileSync } from 'node:fs';
import { DatabaseSync } from 'node:sqlite';
import { jobsSchemaFile } from '$DIR/worker/jobs/test/lib/jobs-schema.js';
new DatabaseSync(process.env.HG_DB).exec(readFileSync(jobsSchemaFile(), 'utf8'));
EOF
cat >"$T/drv.mjs" <<EOF
import { DatabaseSync } from 'node:sqlite';
import worker from '$DIR/worker/jobs/src/index.js';
import { d1 } from '$DIR/worker/jobs/test/lib/d1-sqlite.bh-1030.js';
const db = new DatabaseSync(process.env.HG_DB);
const [method, url, body] = process.argv.slice(2);
const res = await worker.fetch(new Request(url, {
  method, headers: { authorization: 'Bearer fixture-secret-9580', 'content-type': 'application/json' },
  body: body ? body : undefined,
}), { DB: d1(db), HARNESS_SECRET: 'fixture-secret-9580' });
process.stdout.write((await res.text()) + '\n' + res.status);
EOF
node "$T/init.mjs" || { bad "the jobs schema did not apply"; done_; }
sql() { node -e '
  const { DatabaseSync } = require("node:sqlite");
  const db = new DatabaseSync(process.env.HG_DB);
  const r = db.prepare(process.argv[1]).all();
  for (const row of r) console.log(Object.values(row).map((v) => v === null ? "NULL" : v).join("\t"));' "$1"; }
setrow() { sql "UPDATE settings SET value='$2' WHERE key='$1' RETURNING key" >/dev/null; }

mkdir -p "$T/fakebin"
cat >"$T/fakebin/curl" <<'STUB'
#!/bin/bash
URL=""; BODY=""; M=GET
while [ $# -gt 0 ]; do
  case "$1" in --data-binary|-d|--data) BODY="$2"; shift 2 ;; -X) M="$2"; shift 2 ;; http*://*) URL="$1"; shift ;; *) shift ;; esac
done
case "$URL" in https://jobs.test*) ;; *) exit 22 ;; esac
case "$BODY" in @-) BODY=$(cat) ;; @*) BODY=$(cat "${BODY#@}") ;; esac
printf '%s %s\n' "$M" "${URL#https://jobs.test}" >> "$HG_T/req.log"
[ -e "$HG_T/outage" ] && exit 7
exec flock "$HG_DB.lock" node "$HG_T/drv.mjs" "$M" "$URL" "$BODY"
STUB
cat >"$T/fakebin/gh" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$HG_T/gh.log"
exit 99
STUB
chmod +x "$T/fakebin/curl" "$T/fakebin/gh"
: > "$T/req.log"; : > "$T/gh.log"

# ── the scratch harness ──────────────────────────────────────────────────────
H="$T/h"
mkdir -p "$H/bin/lib" "$H/env" "$H/logs" "$H/state" "$H/builds" "$H/flags"
for L in bin/jobs-client.sh bin/jobs-client.d/bh-9580-human-gate-put.sh bin/lib/human-gate.sh \
         bin/lib/human-gate-release.d/plan.sh bin/lib/human-gate-release.d/conductor.sh \
         bin/lib/human-gate-release.d/tackler.sh bin/lib/human-gate-release.d/needs-human.sh \
         bin/lib/plan-blocked.sh bin/lib/client-questions.sh bin/transcript-scrub.sh bin/fleet-conf.sh; do
  ( cd "$DIR" && scratch_install_closure "$L" "$H" ) >/dev/null || { bad "setup: could not install $L"; done_; }
done
for L in $(cd "$DIR" && printf '%s ' bin/lib/jobs/*.sh); do
  ( cd "$DIR" && scratch_install_closure "$L" "$H" ) >/dev/null || { bad "setup: could not install $L"; done_; }
done
printf 'HARNESS_SECRET=fixture-secret-9580\nJOBS_URL=https://jobs.test\n' > "$H/env/global.env"
# The requeue writer hgr_plan calls: a fake that records its argv.
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/qlp.log"\n' "$T" > "$H/bin/queue-line-put.sh"
chmod +x "$H/bin/queue-line-put.sh"
export HARNESS="$H" FLEET_CONF="$DIR/fleet.conf" HARNESS_ENV_DIR="$H/env" \
  HARNESS_SECRET=fixture-secret-9580 JOBS_URL=https://jobs.test JOBS_RETRIES=0 \
  PATH="$T/fakebin:$PATH" GH_TOKEN_LIVE_FILE="$T/no-such-token"
unset GH_TOKEN HG_JOBS_CLIENT 2>/dev/null

# shellcheck source=bin/lib/human-gate.sh
. "$H/bin/lib/human-gate.sh" || { bad "bin/lib/human-gate.sh does not load"; done_; }
posts() { grep -c '^POST /api/human-gates$' "$T/req.log"; }
P=cromford

# The gate blocks of run-build, lifted by their markers (plan-blocked-marker-test idiom).
. "$DIR/tests/lib/rb-all.sh" || exit 1
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh")
cut_block() { awk -v n="$1" 'index($0,"# >>> " n)==1{f=1;next} index($0,"# <<< " n)==1{exit} f' "$RB_ALL" > "$2"; }
cut_block "plan blocked marker" "$T/marker.sh"
cut_block "human gate lib (BH-9559)" "$T/hglib.sh"
cut_block "plan blocked gate" "$T/gate.sh"
for f in marker hglib gate; do [ -s "$T/$f.sh" ] && ok || bad "could not lift the '$f' block from bin/lib/rb/plan.sh"; done
grep -q 'hg_plan_blocked' "$T/gate.sh" && ok || bad "the plan blocked gate does not call hg_plan_blocked"

plan_md() { # plan_md <file> <tag>: a BLOCKED plan with one client question, 2 reasons
  cat > "$1" <<EOF
BLOCKED: the ticket does not say who sets the fee ($2).

\`\`\`client-questions
[{"question": "Does the rep set the fee per client ($2)?", "recommended": "yes, per client", "reasons": ["the ticket says per client", "no new table"], "default": "yes, per client"}]
\`\`\`
EOF
}
GRC=""
drive_gate() { # drive_gate <key> <build-dir>
  mkdir -p "$2"; plan_md "$2/plan.md" "$1"; : > "$2/pipeline.log"
  BUILD="$2" PROJECT="$P" KEY="$1" bash -c '
    set -uo pipefail
    BB() { :; }
    RESULT() { echo "$*" > "$BUILD/RESULT"; }
    . "$1"; . "$2"; . "$3"' _ "$T/marker.sh" "$T/hglib.sh" "$T/gate.sh" >/dev/null 2>&1
  GRC=$?
}
notice() { # notice <key> <build-dir> -> the posted body in $T/posted.txt
  rm -f "$T/posted.txt"
  ( # shellcheck source=bin/lib/plan-blocked.sh
    . "$H/bin/lib/plan-blocked.sh" || exit 9
    gh_token_live() { :; }
    gh_rest_comment() { cp "$3" "$T/posted.txt"; }
    pb_notice "$H" "$P" "" "$1" "$2" >"$T/notice.out" 2>&1 )
}
LABELS=('Question: ' 'Recommended answer: ' 'Reasons: ' 'Default: ' 'Deadline (UTC): ')
has_labels() { local l; for l in "${LABELS[@]}"; do grep -q "^$l" "$1" 2>/dev/null || return 1; done; }

# ══ F1 planner block ══════════════════════════════════════════════════════════
K=BH-95801; B="$H/builds/$P-$K-1"
drive_gate "$K" "$B"
[ "$GRC" = 4 ] && ok || bad "F1: the gate ended rc $GRC, want 4"
grep -q '^PLAN_BLOCKED ' "$B/RESULT" 2>/dev/null && ok || bad "F1: RESULT is not PLAN_BLOCKED: $(cat "$B/RESULT" 2>/dev/null)"
has_labels "$B/human-gates.md" && ok || bad "F1: human-gates.md lacks the 5 fields: $(cat "$B/human-gates.md" 2>/dev/null) | log: $(cat "$B/pipeline.log")"
grep -q '^Reasons: the ticket says per client; no new table$' "$B/human-gates.md" 2>/dev/null && ok || bad "F1: the Reasons line is wrong"
grep -qE '^Deadline \(UTC\): [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2} UTC$' "$B/human-gates.md" 2>/dev/null && ok || bad "F1: the Deadline line is wrong"
ROW=$(sql "SELECT lane, reason, gate_class, status, deadline_at IS NOT NULL, asked_again_at IS NULL FROM human_gates WHERE repo='$P' AND key='$K'")
[ "$ROW" = $'plan\tplan_blocked\tdefaultable\topen\t1\t1' ] && ok || bad "F1: the human_gates row is [$ROW]"
DL=$(sql "SELECT deadline_at FROM human_gates WHERE key='$K'")
grep -qF "Deadline (UTC): ${DL:0:10} ${DL:11:5} UTC" "$B/human-gates.md" && ok || bad "F1: the printed deadline is not the row's ($DL)"
grep -q 'human-gate: 1 gate(s) written' "$B/pipeline.log" && ok || bad "F1: no 'gate(s) written' line in pipeline.log"
notice "$K" "$B"
has_labels "$T/posted.txt" && ok || bad "F1: the plan comment lacks the 5 fields: $(cat "$T/posted.txt" 2>/dev/null) | $(cat "$T/notice.out")"
grep -q '^We stopped before building this one' "$T/posted.txt" 2>/dev/null && ok || bad "F1: the comment lost its intro"
# A re-plan with the same question: the same row, re-asked, same deadline.
B2="$H/builds/$P-$K-2"; drive_gate "$K" "$B2"
[ "$(sql "SELECT count(*) FROM human_gates WHERE key='$K'")" = 1 ] && ok || bad "F1: a re-plan wrote a second row"
[ "$(sql "SELECT asked_again_at IS NOT NULL, deadline_at FROM human_gates WHERE key='$K'")" = $'1\t'"$DL" ] && ok || bad "F1: the re-ask changed the deadline or did not stamp asked_again_at"
[ -s "$T/gh.log" ] && bad "F1: gh was called: $(head -3 "$T/gh.log")" || ok

# ══ F2-F4 the refusals ════════════════════════════════════════════════════════
refused() { # refused <label> <hg_ask args...>
  local label="$1" n0 out err rc; shift
  n0=$(posts)
  out=$(hg_ask "$@" 2>"$T/err"); rc=$?; err=$(cat "$T/err")
  [ "$rc" = 2 ] && ok || bad "$label: rc $rc, want 2"
  [ -z "$out" ] && ok || bad "$label: printed [$out]"
  [ "$(grep -c . <<<"$err")" = 1 ] && grep -q '^hg_ask: refused: ' <<<"$err" && ok || bad "$label: stderr is not one refused line: [$err]"
  [ "$(posts)" = "$n0" ] && ok || bad "$label: a POST went out"
}
A=("$P" BH-95802 plan plan_blocked "Ship it?")
refused "F2 no --"            "${A[@]}" yes r1
refused "F2 blank default"    "${A[@]}" yes r1 -- "   "
refused "F2 two defaults"     "${A[@]}" yes r1 -- d1 d2
refused "F3 no recommended"   "${A[@]}" "" r1 -- d
refused "F3 blank recommended" "${A[@]}" "  " r1 -- d
refused "F4 0 reasons"        "${A[@]}" yes -- d
refused "F4 4 reasons"        "${A[@]}" yes r1 r2 r3 r4 -- d
refused "F4 a blank reason"   "${A[@]}" yes r1 " " -- d
refused "F2 no question"      "$P" BH-95802 plan plan_blocked " " yes r1 -- d
[ "$(sql "SELECT count(*) FROM human_gates WHERE key='BH-95802'")" = 0 ] && ok || bad "F2-F4: a refused call wrote a row"
OUT=$(hg_ask "$P" BH-95804 plan plan_blocked "One reason?" yes "only one" -- no); RC=$?
[ "$RC" = 0 ] && [ "$(grep -c . <<<"$OUT")" = 5 ] && grep -q '^Reasons: only one$' <<<"$OUT" && ok || bad "F4 1 reason: rc $RC [$OUT]"
OUT=$(hg_ask "$P" BH-95804 plan plan_blocked "Three reasons?" yes a b c -- no); RC=$?
[ "$RC" = 0 ] && grep -q '^Reasons: a; b; c$' <<<"$OUT" && grep -q '^Default: no$' <<<"$OUT" && ok || bad "F4 3 reasons: rc $RC [$OUT]"
[ "$(sql "SELECT count(*) FROM human_gates WHERE key='BH-95804'")" = 2 ] && ok || bad "F4: the two accepted asks did not write 2 rows"

# ══ F5 the kill flag ══════════════════════════════════════════════════════════
setrow human_gate.format.enabled 0
N0=$(posts)
OUT=$(hg_ask "$P" BH-95805 plan plan_blocked "Flag off?" yes r1 -- d 2>&1); RC=$?
[ "$RC" = 0 ] && [ -z "$OUT" ] && ok || bad "F5: flag 0: rc $RC, output [$OUT]"
[ "$(posts)" = "$N0" ] && ok || bad "F5: flag 0 still POSTed"
B="$H/builds/$P-BH-95805-1"; drive_gate BH-95805 "$B"
[ "$GRC" = 4 ] && ok || bad "F5: the gate ended rc $GRC, want 4"
[ -e "$B/human-gates.md" ] && bad "F5: flag 0 wrote human-gates.md" || ok
[ "$(sql "SELECT count(*) FROM human_gates WHERE key='BH-95805'")" = 0 ] && ok || bad "F5: flag 0 wrote a row"
notice BH-95805 "$B"
grep -q '^Recommended: yes, per client$' "$T/posted.txt" 2>/dev/null && ok || bad "F5: the comment is not the old cq text: $(cat "$T/posted.txt" 2>/dev/null) | $(cat "$T/notice.out")"
grep -q 'Deadline (UTC)' "$T/posted.txt" 2>/dev/null && bad "F5: flag 0 still posted a deadline" || ok
setrow human_gate.format.enabled 1

# ══ F6 hg_class ═══════════════════════════════════════════════════════════════
cls() { local got; got=$(hg_class "$1"); [ "$got" = "$2" ] && ok || bad "F6: hg_class '$1' = $got, want $2"; }
for r in plan_blocked tightened needs-human parked; do cls "$r" defaultable; done
for r in migration-gated hotfix-migration-hold provenance security-allowlist Migration-Gated migration-gated-v2 \
         "plan_blocked " "" plan/blocked never-seeded; do cls "$r" irreversible; done
setrow human_gate.class.parked Defaultable; cls parked irreversible; setrow human_gate.class.parked defaultable
touch "$T/outage"; cls plan_blocked irreversible; rm -f "$T/outage"

# ══ F7 hg_release plan ═══════════════════════════════════════════════════════
: > "$T/qlp.log"
hg_release plan "$P" BH-123 "yes, per client" 2>"$T/err"; RC=$?
[ "$RC" = 0 ] && ok || bad "F7: hg_release plan rc $RC: $(cat "$T/err")"
[ "$(cat "$T/qlp.log")" = "cromford BH-123 123 M feature human-gate answer (plan): yes, per client" ] && ok \
  || bad "F7: queue-line-put got [$(cat "$T/qlp.log")]"

# ══ F8 hg_release on a placeholder and a bad lane ═════════════════════════════
hg_release conductor "$P" BH-123 yes 2>"$T/err"; RC=$?
[ "$RC" = 3 ] && [ "$(grep -c . "$T/err")" = 1 ] && grep -q 'defines no hgr_conductor' "$T/err" && ok || bad "F8: conductor rc $RC [$(cat "$T/err")]"
hg_release needs-human "$P" BH-123 yes 2>/dev/null; RC=$?
[ "$RC" = 3 ] && ok || bad "F8: needs-human rc $RC, want 3"
hg_release Bad/lane "$P" BH-123 yes 2>/dev/null; RC=$?
[ "$RC" = 2 ] && ok || bad "F8: a bad lane rc $RC, want 2"
hg_release no-such-lane "$P" BH-123 yes 2>/dev/null; RC=$?
[ "$RC" = 3 ] && ok || bad "F8: a missing lane file rc $RC, want 3"

# ══ F9 the seams and the docs ═════════════════════════════════════════════════
for f in conductor tackler needs-human; do
  p="$DIR/bin/lib/human-gate-release.d/$f.sh"
  [ "$(wc -l < "$p")" = 2 ] && grep -q '^# owner: BH-9559.2' "$p" && ok || bad "F9: $p is not the 2-line placeholder"
  grep -qE '^[a-z_]+ *\(\)' "$p" && bad "F9: $p defines a function" || ok
done
for s in human-gates/conductor.md:BH-9559.2 human-gates/defaults.md:BH-9559.3 human-gates/digest-and-replies.md:BH-9559.4 \
         human-gates/review-dates.md:BH-9559.5 gates/prequeue-fresh-main.md:BH-9559.8 gates/builder-topred.md:BH-9559.9; do
  f="$DIR/docs/${s%%:*}"
  head -1 "$f" 2>/dev/null | grep -q '^# ' && grep -qx "owner: ${s##*:}" "$f" && ok || bad "F9: stub $f is not a heading plus 'owner: ${s##*:}'"
done
grep -q '^## Human gates$' "$DIR/docs/CUSTODY.md" && ok || bad "F9: docs/CUSTODY.md has no ## Human gates"
[ "$(grep -oE '\(human-gates/[a-z-]+\.md\)' "$DIR/docs/CUSTODY.md" | sort -u | wc -l)" = 4 ] && ok || bad "F9: CUSTODY does not link the 4 stubs"
links() { grep -oE '\]\([a-z/.-]+\.md\)' "$1" | sed 's/^](//; s/)$//'; }
for d in CUSTODY GATES-VS-REPORTS; do
  while IFS= read -r l; do [ -f "$DIR/docs/$l" ] && ok || bad "F9: docs/$d.md links $l, which does not exist"; done < <(links "$DIR/docs/$d.md" | grep gates/)
done
grep -q '^## Human gates$' "$DIR/docs/GATES-VS-REPORTS.md" && grep -q '(gates/prequeue-fresh-main.md)' "$DIR/docs/GATES-VS-REPORTS.md" \
  && grep -q '(gates/builder-topred.md)' "$DIR/docs/GATES-VS-REPORTS.md" && ok || bad "F9: GATES-VS-REPORTS lacks its Human gates paragraph or links"
grep -q '(human-gates/conductor.md)' "$DIR/docs/MERGE-CONDUCTOR.md" && ok || bad "F9: MERGE-CONDUCTOR does not link human-gates/conductor.md"

# ══ F10 the worker is down ════════════════════════════════════════════════════
touch "$T/outage"
OUT=$(hg_ask "$P" BH-95810 plan plan_blocked "Down?" yes r1 -- d 2>/dev/null); RC=$?
[ "$RC" = 1 ] && [ -z "$OUT" ] && ok || bad "F10: hg_ask rc $RC, output [$OUT], want rc 1 and nothing"
B="$H/builds/$P-BH-95810-1"; drive_gate BH-95810 "$B"
[ "$GRC" = 4 ] && grep -q '^PLAN_BLOCKED ' "$B/RESULT" && ok || bad "F10: the gate ended rc $GRC, want 4 / PLAN_BLOCKED"
[ -e "$B/human-gates.md" ] && bad "F10: an outage left a human-gates.md" || ok
grep -q 'human-gate: question 1 not written' "$B/pipeline.log" && ok || bad "F10: pipeline.log does not name the failure: $(cat "$B/pipeline.log")"
rm -f "$T/outage"

[ -s "$T/gh.log" ] && bad "gh was called: $(head -3 "$T/gh.log")" || ok
done_
