#!/bin/bash
# tests/pr-self-check-gating.bh-7074-test.sh — BH-7074: the pre-review
# self-check refuses a GATING diff whose PR body has no fenced ```live-probes
# block with valid probe lines and a `KILL KNOB:` line. The rule is
# body-live-probes-gating (bin/lib/pr-self-check-gating.sh, the row in
# catalog/pr-self-check.d/bh-7074-live-probes-gating.tsv).
#
#   A1-A6  the ticket's acceptance cases, through bin/pr-self-check.sh
#   D1-D9  psc_gating_triggers: settings, cron and route triggers, and the
#          adversarial negatives that must not fire
#   B1-B7  the body: catalog probe, unknown probe, write verb, shell command,
#          KILL KNOB outside the fence, empty KILL KNOB, CRLF, a new catalog row
#   E1-E2  no catalog at head = no line; a base that does not resolve = rc 2
#   W1-W3  mode note; the full catalog in a repo with no live-probes catalog;
#          gate 78's classifier (lgsc_refusals body) lists the rule
#   R1     lp_declared reads the passing body; the lane's _lp_body rewrite
#          keeps the fence, and the rule still passes on it
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/pr-self-check-gating.bh-7074-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
SRC=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
unset PR_SELF_CHECK_CATALOG PR_SELF_CHECK_ONLY PSC_TICKET_FILE PSC_PR_KEY LIVE_PROBES_CATALOG

H="$T/h"; mkdir -p "$H" "$T/tmp" "$T/b"
scratch_install_closure bin/pr-self-check.sh "$H" >/dev/null || { echo "FAIL: closure of bin/pr-self-check.sh"; exit 1; }
scratch_install_closure bin/lib/lead-gates-selfcheck.sh "$H" >/dev/null || { echo "FAIL: closure of bin/lib/lead-gates-selfcheck.sh"; exit 1; }
CAT="$SRC/catalog/pr-self-check.tsv"   # the real main file and its real .d/
[ -r "$SRC/bin/lib/pr-self-check-gating.sh" ] && [ -r "$SRC/catalog/pr-self-check.d/bh-7074-live-probes-gating.tsv" ] || { echo "FAIL: the rule lib or its catalog row is missing"; exit 1; }
export TMPDIR="$T/tmp"
RULE='body-live-probes-gating'

# ── the fixture repo: the real probe catalog, two cron lanes, a schema.d file ─
R="$T/repo"; mkdir -p "$R/catalog" "$R/cron/lanes" "$R/cron/boxes/hub" "$R/worker/jobs/schema.d" "$R/bin" "$R/docs" "$R/tests"
git -C "$R" init -q -b main
cp "$SRC/catalog/live-probes.tsv" "$R/catalog/live-probes.tsv"
printf '*/10 * * * * /root/harness/bin/x.sh\n' > "$R/cron/lanes/240-x.cron"
printf '*/5 * * * * /root/harness/bin/hub-lease.sh check && /root/harness/bin/y.sh\n' > "$R/cron/lanes/250-y.cron"
printf '7 * * * * /root/harness/bin/z.sh\n' > "$R/cron/boxes/hub/z.cron"
printf "INSERT OR IGNORE INTO settings (key, value) VALUES ('lane_placement.old-lane', 'hub');\n" > "$R/worker/jobs/schema.d/202610010000-bh-1-old.sql"
printf '#!/bin/bash\necho y\n' > "$R/bin/y.sh"
git -C "$R" add -A; git -C "$R" commit -qm M0

# br <name> — a fresh branch from main
br() { git -C "$R" checkout -q main && git -C "$R" checkout -qB "$1" && mkdir -p "$R/docs" "$R/tests" "$R/bin"; }
cm() { git -C "$R" add -A && git -C "$R" commit -qm "$1"; }
# run <branch> <body> [catalog] — the CLI, the rule alone; OUT, RC
run() {
  OUT=$(PR_SELF_CHECK_CATALOG="${3:-$CAT}" bash "$H/bin/pr-self-check.sh" check \
        --repo "$R" --base main --head "$1" --body "$2" --only "^$RULE\$" 2>/dev/null); RC=$?
}
# trig <branch> — psc_gating_triggers on the branch; TRIG
trig() {
  git -C "$R" show "$1:catalog/live-probes.tsv" > "$T/cat.tsv" 2>/dev/null
  TRIG=$(bash -c '. "$1/bin/lib/pr-self-check.sh"; psc_gating_triggers "$2" main "$3" "$4"' _ "$H" "$R" "$1" "$T/cat.tsv" 2>&1)
}
has()  { grep -qF -- "$2" <<<"$1"; }
body() { printf '%s\n' "$2" > "$T/b/$1"; printf '%s' "$T/b/$1"; }

FENCE_OK=$'## Summary\nSeeds a placement row.\n\n```live-probes\nprobe: hub-request bin/lane-fleet-probe.sh\nKILL KNOB: lane_placement.blocked-resolver=hub\n```\n'
B_OK=$(body ok.md "$FENCE_OK")
B_NONE=$(body none.md $'## Summary\nSeeds a placement row.\n')

# ── A1/A2: a lane_placement settings seed in schema.d ─────────────────────────
br a1
printf -- "-- BH-x: place the resolver on the hub\nINSERT OR IGNORE INTO settings (key, value, updated_at) VALUES ('lane_placement.blocked-resolver','hub',0);\n" \
  > "$R/worker/jobs/schema.d/202610170600-bh-x-y.sql"
cm a1
run a1 "$B_NONE"
{ [ "$RC" = 1 ] && has "$OUT" "REFUSE $RULE:" && has "$OUT" "worker/jobs/schema.d/202610170600-bh-x-y.sql:2"; } \
  && ok || bad "A1 settings seed, no block: want rc 1 naming schema.d file:2, got rc $RC: $OUT"
A1_OUT="$OUT"
run a1 "$B_OK"
{ [ "$RC" = 0 ] && [ -z "$OUT" ]; } && ok || bad "A2 hub-request + KILL KNOB: want rc 0 and no output, got rc $RC: $OUT"

# ── A3: a catalog route read, with only a prose section and 39 pasted rows ────
br a3
printf '#!/bin/bash\nr=example-org/cromford\n_jobs_req GET "/api/lead-protected-paths?repo=$r"\n' > "$R/bin/x.sh"
cm a3
{ printf '## Summary\nReads the protected paths.\n\n## Live probes\nI ran this by hand on the hub:\nprobe: lead-protected-paths\nKILL KNOB: none needed\n'
  for i in $(seq 1 39); do printf 'lead-protected-paths\tjobs-get\t/api/lead-protected-paths?repo=example-org/cromford\trow %s ok\n' "$i"; done
} > "$T/b/prose.md"
run a3 "$T/b/prose.md"
{ [ "$RC" = 1 ] && has "$OUT" "bin/x.sh:3"; } && ok || bad "A3 prose probe section: want rc 1 naming bin/x.sh:3, got rc $RC: $OUT"

# ── A4: a diff that gates nothing needs no block ──────────────────────────────
br a4
printf '#!/bin/bash\necho y2\n' > "$R/bin/y.sh"
printf 'The lane reads /api/flags and lane_placement.x.\n' > "$R/docs/z.md"
printf 'CREATE TABLE IF NOT EXISTS foo (id INTEGER);\nCREATE INDEX IF NOT EXISTS foo_id ON foo(id);\n' > "$R/worker/jobs/schema.d/202610170601-bh-x-foo.sql"
cm a4
run a4 "$B_NONE"
{ [ "$RC" = 0 ] && [ -z "$OUT" ]; } && ok || bad "A4 non-gating diff: want rc 0 and no output, got rc $RC: $OUT"

# ── A5: a hub-lease && precondition on a cron lane, no KILL KNOB ──────────────
br a5
printf '*/10 * * * * /root/harness/bin/hub-lease.sh check && /root/harness/bin/x.sh\n' > "$R/cron/lanes/240-x.cron"
cm a5
B_NOKNOB=$(body noknob.md $'## Summary\nGates x.\n\n```live-probes\nprobe: hub-lease\n```\n')
run a5 "$B_NOKNOB"
{ [ "$RC" = 1 ] && has "$OUT" "cron/lanes/240-x.cron:1" && has "$OUT" "KILL KNOB"; } \
  && ok || bad "A5 cron precondition, no KILL KNOB: want rc 1 naming cron/lanes/240-x.cron:1, got rc $RC: $OUT"
B_A5OK=$(body a5ok.md $'```live-probes\nprobe: hub-lease\nKILL KNOB: remove the hub-lease check from cron/lanes/240-x.cron\n```\n')
run a5 "$B_A5OK"
{ [ "$RC" = 0 ] && [ -z "$OUT" ]; } && ok || bad "A5b catalog probe + KILL KNOB: want rc 0, got rc $RC: $OUT"

# ── A6: more than 5 triggers: 5 named, then "and N more" ──────────────────────
br a6
for i in 1 2 3 4 5 6 7; do printf "('lane_placement.l%s','hub'),\n" "$i"; done > "$R/worker/jobs/schema.d/202610170602-bh-x-many.sql"
cm a6
run a6 "$B_NONE"
{ [ "$RC" = 1 ] && has "$OUT" "202610170602-bh-x-many.sql:5 " && ! has "$OUT" "202610170602-bh-x-many.sql:6" && has "$OUT" "and 2 more"; } \
  && ok || bad "A6 seven triggers: want 5 named and 'and 2 more', got: $OUT"

# ── D1-D9: the trigger decision rule ─────────────────────────────────────────
trig a1; { has "$TRIG" $'worker/jobs/schema.d/202610170600-bh-x-y.sql\t2\t' && [ "$(wc -l <<<"$TRIG")" = 1 ]; } && ok || bad "D1a lane_placement seed: got $TRIG"
br d1
printf "INSERT OR IGNORE INTO settings (key, value) VALUES ('lead.require_builder_approve','1');\n" > "$R/worker/jobs/schema.d/202610170603-bh-x-req.sql"
cm d1
trig d1; has "$TRIG" $'202610170603-bh-x-req.sql\t1\t' && ok || bad "D1b *.require_* seed: got $TRIG"

br d2
{ printf -- "-- ('lane_placement.blocked-resolver','hub')\n"
  printf "   -- seeds 'lead.require_x' later\n"
  printf "INSERT OR IGNORE INTO settings (key, value) VALUES ('lane_placement_x','hub'), ('lane_placement','hub'), ('require_x','1');\n"
} > "$R/worker/jobs/schema.d/202610170604-bh-x-neg.sql"
git -C "$R" rm -q worker/jobs/schema.d/202610010000-bh-1-old.sql
cm d2
trig d2; [ -z "$TRIG" ] && ok || bad "D2 settings negatives (comment, no dot, removed line): want none, got $TRIG"

br d3
mkdir -p "$R/worker/other/schema.d"
printf "INSERT INTO settings VALUES ('lane_placement.x','hub');\n" > "$R/worker/other/schema.d/1.sql"
printf "INSERT INTO settings VALUES ('lane_placement.x','hub');\n" > "$R/docs/seed.sql"
cm d3
trig d3; [ -z "$TRIG" ] && ok || bad "D3 settings key outside worker/jobs/schema.d: want none, got $TRIG"

trig a5; has "$TRIG" $'cron/lanes/240-x.cron\t1\t' && ok || bad "D4a && added before a lane: got $TRIG"
br d4
printf '*/5 * * * * /root/harness/bin/hub-lease.sh check && /root/harness/bin/flag-on.sh y && /root/harness/bin/y.sh\n' > "$R/cron/lanes/250-y.cron"
printf '9 * * * * /root/harness/bin/hub-lease.sh check && /root/harness/bin/z.sh\n' > "$R/cron/boxes/hub/z.cron"
cm d4
trig d4; { has "$TRIG" $'cron/lanes/250-y.cron\t1\t' && has "$TRIG" $'cron/boxes/hub/z.cron\t1\t'; } \
  && ok || bad "D4b a second && and a box cron with a new schedule: got $TRIG"

br d5
git -C "$R" mv cron/lanes/250-y.cron cron/lanes/251-y.cron
printf '*/3 * * * * /root/harness/bin/hub-lease.sh check && /root/harness/bin/new-lane.sh\n' > "$R/cron/lanes/260-new.cron"
printf '*/10 * * * * /root/harness/bin/flag-on.sh x || /root/harness/bin/x.sh\n# */10 * * * * a && b && /root/harness/bin/z.sh\n' > "$R/cron/lanes/240-x.cron"
cm d5
trig d5; [ -z "$TRIG" ] && ok || bad "D5 cron negatives (moved line, new lane, ||, comment): want none, got $TRIG"

br d6
printf '*/10 * * * * /root/harness/bin/x.sh\n' > "$R/cron/lanes/240-x.cron.bak"
printf 'cron line: */10 * * * * a && /root/harness/bin/x.sh\n' > "$R/docs/cron.md"
cm d6
trig d6; [ -z "$TRIG" ] && ok || bad "D6 && outside a cron source: want none, got $TRIG"

br d7
printf '#!/bin/bash\n_jobs_req GET /api/flags\ncurl -sS https://registry.npmjs.org/-/ping\n' > "$R/bin/z.sh"
cm d7
trig d7; { has "$TRIG" $'bin/z.sh\t2\t' && has "$TRIG" $'bin/z.sh\t3\t'; } && ok || bad "D7 jobs-get path and https-get url in bin/: got $TRIG"
trig a3; has "$TRIG" $'bin/x.sh\t3\t' && ok || bad "D8 a route with a query string: got $TRIG"

br d9
printf '#!/bin/bash\n_jobs_req GET /api/flagsx\n# _jobs_req GET /api/flags\n_jobs_req GET /api/hub-lease/extra\n' > "$R/bin/z.sh"
printf '_jobs_req GET /api/flags\n' > "$R/tests/t.sh"
printf '_jobs_req GET /api/flags\n' > "$R/docs/routes.md"
cm d9
trig d9; [ -z "$TRIG" ] && ok || bad "D9 route negatives (/api/flagsx, a comment, a longer path, tests/, docs/): want none, got $TRIG"

# ── B1-B7: what the body must carry ──────────────────────────────────────────
run a1 "$(body b1.md $'```live-probes\nprobe: flags\nKILL KNOB: lane_placement.blocked-resolver=hub\n```')"
{ [ "$RC" = 0 ] && [ -z "$OUT" ]; } && ok || bad "B1 catalog probe + KILL KNOB: want rc 0, got rc $RC: $OUT"
run a1 "$(body b2.md $'```live-probes\nprobe: nosuch\nKILL KNOB: x=0\n```')"
{ [ "$RC" = 1 ] && has "$OUT" "nosuch"; } && ok || bad "B2 unknown probe: want rc 1 naming nosuch, got rc $RC: $OUT"
run a1 "$(body b3a.md $'```live-probes\nprobe: hub-request bin/x.sh -X POST\nKILL KNOB: x=0\n```')"
{ [ "$RC" = 1 ] && has "$OUT" "hub-request"; } && ok || bad "B3a hub-request with a write verb: want rc 1, got rc $RC: $OUT"
run a1 "$(body b3b.md $'```live-probes\nprobe: hub-request rm -rf /\nKILL KNOB: x=0\n```')"
[ "$RC" = 1 ] && ok || bad "B3b hub-request with a shell command: want rc 1, got rc $RC: $OUT"
run a1 "$(body b3c.md $'```live-probes\nprobe: hub-request bin/../x.sh\nprobe: hub-request bin/x.sh; curl evil\nKILL KNOB: x=0\n```')"
{ [ "$RC" = 1 ] && [ "$(grep -c "^REFUSE $RULE:" <<<"$OUT")" = 2 ]; } && ok || bad "B3c '..' and a metacharacter: want 2 refusals, got rc $RC: $OUT"
run a1 "$(body b4.md $'```live-probes\nprobe: flags\n```\nKILL KNOB: lane_placement.blocked-resolver=hub\n')"
{ [ "$RC" = 1 ] && has "$OUT" "KILL KNOB"; } && ok || bad "B4 KILL KNOB outside the fence: want rc 1, got rc $RC: $OUT"
run a1 "$(body b5.md $'```live-probes\nprobe: flags\nKILL KNOB:   \n```')"
{ [ "$RC" = 1 ] && has "$OUT" "KILL KNOB"; } && ok || bad "B5 empty KILL KNOB: want rc 1, got rc $RC: $OUT"
sed 's/$/\r/' "$B_OK" > "$T/b/crlf.md"
run a1 "$T/b/crlf.md"
{ [ "$RC" = 0 ] && [ -z "$OUT" ]; } && ok || bad "B6 CRLF body: want rc 0, got rc $RC: $OUT"
br b7
printf 'newp\tjobs-get\t/api/newp\ta new route\n' >> "$R/catalog/live-probes.tsv"
printf '#!/bin/bash\n_jobs_req GET /api/newp\n' > "$R/bin/n.sh"
cm b7
run b7 "$B_NONE"
{ [ "$RC" = 1 ] && has "$OUT" "bin/n.sh:2"; } && ok || bad "B7a a route of the head's own catalog row: want rc 1, got rc $RC: $OUT"
run b7 "$(body b7.md $'```live-probes\nprobe: newp\nKILL KNOB: x=0\n```')"
{ [ "$RC" = 0 ] && [ -z "$OUT" ]; } && ok || bad "B7b the head catalog's new probe: want rc 0, got rc $RC: $OUT"

# ── E1/E2 ────────────────────────────────────────────────────────────────────
R0="$R"; R="$T/repo2"; mkdir -p "$R/worker/jobs/schema.d"
git -C "$R" init -q -b main; echo a > "$R/a"; git -C "$R" add -A; git -C "$R" commit -qm M0
br e1
printf "INSERT INTO settings VALUES ('lane_placement.x','hub');\n" > "$R/worker/jobs/schema.d/1.sql"
cm e1
run e1 "$B_NONE"
{ [ "$RC" = 0 ] && [ -z "$OUT" ]; } && ok || bad "E1 no catalog/live-probes.tsv at head: want rc 0 and no output, got rc $RC: $OUT"
# W2: the same repo through the full catalog: no line for this rule
OUT=$(PR_SELF_CHECK_CATALOG="$CAT" bash "$H/bin/pr-self-check.sh" check --repo "$R" --base main --head e1 --body "$B_NONE" 2>/dev/null)
! has "$OUT" "$RULE" && ok || bad "W2 full catalog, another repo: want no $RULE line, got: $OUT"
R="$R0"
OUT=$(PR_SELF_CHECK_CATALOG="$CAT" bash "$H/bin/pr-self-check.sh" check --repo "$R" --base nosuch --head a1 --body "$B_NONE" --only "^$RULE\$" 2>/dev/null); RC=$?
[ "$RC" = 2 ] && ok || bad "E2 a base that does not resolve: want rc 2, got rc $RC: $OUT"

# ── W1: mode note ────────────────────────────────────────────────────────────
mkdir -p "$T/catn"
printf '%s\tnote\t-\tthe gating block\t-\n' "$RULE" > "$T/catn/pr-self-check.tsv"
run a1 "$B_NONE" "$T/catn/pr-self-check.tsv"
{ [ "$RC" = 0 ] && has "$OUT" "NOTE $RULE:" && ! has "$OUT" "REFUSE"; } && ok || bad "W1 mode note: want a NOTE line and rc 0, got rc $RC: $OUT"

# ── W3: gate 78's classifier holds on it ─────────────────────────────────────
printf '%s\n' "$A1_OUT" > "$T/a1.out"
W3=$(bash -c '. "$1/bin/lib/lead-gates-selfcheck.sh"; LGSC_OUT="$2"; lgsc_refusals body' _ "$H" "$T/a1.out")
has "$W3" "$RULE:" && ok || bad "W3 lgsc_refusals body: want the rule listed, got: $W3"

# ── R1: the live-probe lane reads the same block, and its rewrite keeps it ───
R1=$(bash -c '. "$1/bin/lib/live-probes.sh"; lp_declared "$2"' _ "$SRC" "$B_OK")
[ "$R1" = $'hub-request\tbin/lane-fleet-probe.sh' ] && ok || bad "R1a lp_declared: got '$R1'"
jq -n --rawfile b "$B_OK" '{body: $b}' > "$T/pr.json"
printf '<!-- live-probes:%s -->\n- `hub-request`: refused: not on the allow-list\n' "$(printf 'a%.0s' $(seq 40))" > "$T/comment.md"
bash -c '. "$1/bin/lib/live-probes.sh"; _lp_body "$2" "$3" "$4"' _ "$SRC" "$T/pr.json" "$T/comment.md" "$T/b/rewritten.md"
run a1 "$T/b/rewritten.md"
{ [ "$RC" = 0 ] && [ -z "$OUT" ] && grep -q '^```live-probes$' "$T/b/rewritten.md"; } && ok || bad "R1b the lane's rewritten body: want rc 0, got rc $RC: $OUT"

echo "pr-self-check-gating (BH-7074): $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
