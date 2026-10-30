#!/bin/bash
# tests/retention-moves.bh-8407-test.sh — every retention rule lives in its own
# worker/jobs/src/routes/retention.d/ fragment, and retention.js holds none
# (BH-8398.1, ticket BH-8407).
#
#   M1 SAME RULES: the RULES retention.js exports, filtered to the names
#      RULES had at $PIN, equal $PIN's RULES rule for rule: the same names,
#      the same count, each entry deep-equal by name (a function compared by
#      name and source). A later fragment adds a rule with a new name, and that
#      is not a change to these. $PIN's worker src comes from `git archive
#      $PIN worker/jobs/src` in a scratch tree. An absent $PIN is a FAIL
#   M2 NO LITERAL: retention.js holds no `rule: "` string; every retention.d/
#      name passes fragmentNames; each fragment imports only from ../../lib/;
#      retention.js still exports COST_ARCHIVE_FLOOR_DAYS = 60
#   M3 MUTATION: with bh-6750-core.js deleted in a scratch copy, M1's
#      comparison is red and names wakes.age
#   M4 FRAGMENTS: `node scripts/retention-build.mjs --print` imports each of
#      the $NFRAG fragments in FRAGS
#
# Scratch trees only, fixed git identity, no network.
#   HARNESS_TEST_SANDBOX=1 bash tests/retention-moves.bh-8407-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
command -v node >/dev/null 2>&1 || { echo "SKIPPED: node is not on PATH"; exit 0; }

# The merge base this ticket was built on: its retention.js holds
# onboarding_runs.finished, and its RULES has 49 entries.
PIN=a43d2f083de99b6e0770c7c0667bffb45f4afc3a
NRULES=49
FRAGS="bh-5563-staff.js bh-6739-hotspot-tickets.js bh-6744-landing-decisions.js bh-6750-core.js
bh-6774-cost-rows.js bh-6822-staff-ticks.js bh-6823-staff-chat.js bh-6824-staff-autonomy.js bh-6877-fly-idle.js
bh-6887-mc-budget.js bh-6889-alert-lines.js bh-6972-alert-decisions.js bh-6977-ticket-edges.js bh-6978-sched.js
bh-6979-sched-ready.js bh-7109-stage-events-daily.js bh-7164-cost-project-hourly.js bh-7243-roadmap.js
bh-7300-docker-pool-leases.js bh-7325-migration-reservations.js bh-7348-docker-pool-results.js
bh-7429-pool-record-files.js bh-7431-pool-markers.js bh-7595-web-vault.js bh-7598-web-task-human-step.js
bh-7722-unblock-decisions.js bh-7732-otp-messages.js bh-7949-onboarding-runs.js bh-7972-prompt-versions.js
bh-8067-pr-records.js"
NFRAG=$(wc -w <<<"$FRAGS")
JOBS="$DIR/worker/jobs"
RET="$JOBS/src/routes/retention.js"

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null

# normalize <worker dir> — that tree's retention.js RULES as JSON.
# A function value becomes {"$fn": name, "src": String(fn)}.
normalize() {
  ( cd "$1" && node --input-type=module -e '
    const m = await import("./src/routes/retention.js");
    const norm = (v) => typeof v === "function" ? { $fn: v.name, src: String(v) }
      : Array.isArray(v) ? v.map(norm)
      : v && typeof v === "object" ? Object.fromEntries(Object.entries(v).map(([k, x]) => [k, norm(x)]))
      : v;
    process.stdout.write(JSON.stringify(norm(m.RULES), null, 1) + "\n");' )
}

# compare <base.json> <branch.json> — rc 0 when the branch, filtered to the
# base names, holds every base rule deep-equal by name, and as many of them.
# Names every difference.
compare() {
  node -e '
    const fs = require("fs");
    const base = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    const got = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
    const names = new Set(base.map((r) => r.rule));
    const kept = got.filter((r) => names.has(r.rule));
    const byName = new Map(kept.map((r) => [r.rule, r]));
    let bad = 0;
    for (const r of base) {
      const g = byName.get(r.rule);
      if (!g) { console.log("missing rule: " + r.rule); bad++; }
      else if (JSON.stringify(g) !== JSON.stringify(r)) { console.log("differs: " + r.rule); bad++; }
    }
    if (base.length !== kept.length) { console.log(`count: base ${base.length}, branch ${kept.length}`); bad++; }
    process.exit(bad ? 1 : 0);' "$1" "$2"
}

# scratch_worker <dir> — a copy of this checkout's worker/jobs (src, scripts, package.json).
scratch_worker() {
  mkdir -p "$1"
  cp -R "$JOBS/src" "$JOBS/scripts" "$JOBS/package.json" "$1/"
  rm -f "$1/src/retention-rules.gen.js"
}

W="$T/w"; scratch_worker "$W"
normalize "$W" >"$T/branch.json" 2>"$T/branch.err" && ok "the branch retention.js loads" \
  || bad "the branch retention.js does not load: $(head -3 "$T/branch.err")"

# ── M1 same rules ─────────────────────────────────────────────────────────────
echo "M1: the same rules as $PIN"
P="$T/pin"; mkdir -p "$P"
if git -C "$DIR" cat-file -e "$PIN^{commit}" 2>/dev/null \
   && git -C "$DIR" archive "$PIN" worker/jobs/src worker/jobs/package.json | tar -x -C "$P" \
   && normalize "$P/worker/jobs" >"$T/base.json" 2>"$T/base.err"; then
  NB=$(node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).length)' "$T/base.json")
  [ "$NB" = "$NRULES" ] && ok "M1 $PIN has $NRULES rules" || bad "M1 $PIN has $NB rules, want $NRULES"
  compare "$T/base.json" "$T/branch.json" >"$T/m1.out" 2>&1 && ok "M1 same names, count and entries" \
    || bad "M1 the branch RULES differ: $(head -5 "$T/m1.out")"
else
  bad "M1 $PIN is not in this checkout or does not load (fetch-depth 0 restores it): $(head -3 "$T/base.err" 2>/dev/null)"
  echo '[]' >"$T/base.json"
fi

# ── M2 no literal ─────────────────────────────────────────────────────────────
echo "M2: no rule literal in retention.js"
N=$(grep -c 'rule: "' "$RET")
[ "$N" = 0 ] && ok "M2 retention.js holds no rule: \" string" || bad "M2 retention.js holds $N rule: \" strings"
GOT=$( cd "$W" && node --input-type=module -e '
  import { readdirSync } from "node:fs";
  const { fragmentNames } = await import("./src/lib/retention-rules.js");
  const all = readdirSync("src/routes/retention.d");
  const keep = fragmentNames(all);
  console.log(keep.length === all.length ? "ok" : "dropped: " + all.filter((n) => !keep.includes(n)).join(","));' 2>&1 )
[ "$GOT" = ok ] && ok "M2 every retention.d/ name passes fragmentNames" || bad "M2 fragmentNames: $GOT"
BADIMP=$(grep -H '^import ' "$JOBS"/src/routes/retention.d/*.js | grep -v ':import .* from "\.\./\.\./lib/[^"]*";$')
[ -z "$BADIMP" ] && ok "M2 each fragment imports only from ../../lib/" || bad "M2 fragment imports outside ../../lib/: $BADIMP"
GOT=$( cd "$W" && node --input-type=module -e '
  const m = await import("./src/routes/retention.js");
  console.log(m.COST_ARCHIVE_FLOOR_DAYS);' 2>&1 )
[ "$GOT" = 60 ] && ok "M2 retention.js exports COST_ARCHIVE_FLOOR_DAYS = 60" || bad "M2 COST_ARCHIVE_FLOOR_DAYS: $GOT"

# ── M3 mutation ───────────────────────────────────────────────────────────────
echo "M3: mutation"
M="$T/m"; scratch_worker "$M"
if [ ! -s "$T/base.json" ] || [ "$(tr -d '[:space:]' <"$T/base.json")" = "[]" ]; then
  bad "M3 has no $PIN baseline to compare against (see M1)"
elif [ -f "$M/src/routes/retention.d/bh-6750-core.js" ]; then
  rm -f "$M/src/routes/retention.d/bh-6750-core.js"
  normalize "$M" >"$T/m.json" 2>/dev/null || echo '[]' >"$T/m.json"
  compare "$T/base.json" "$T/m.json" >"$T/m3.out" 2>&1; RC=$?
  [ "$RC" != 0 ] && grep -q 'missing rule: wakes.age' "$T/m3.out" && ok "M3 M1 goes red and names wakes.age" \
    || bad "M3 M1 must be red without bh-6750-core.js: rc $RC $(head -3 "$T/m3.out")"
else
  bad "M3 no bh-6750-core.js fragment to delete"
fi

# ── M4 count ──────────────────────────────────────────────────────────────────
echo "M4: fragments"
( cd "$W" && node scripts/retention-build.mjs --print ) >"$T/print.js" 2>"$T/print.err"; RC=$?
[ "$RC" = 0 ] && ok "M4 --print rc 0" || bad "M4 --print rc $RC: $(head -2 "$T/print.err")"
MISS=""
for f in $FRAGS; do
  grep -qx "import \* as f[0-9]* from \"\./routes/retention\.d/$f\";" "$T/print.js" || MISS="$MISS $f"
done
[ -z "$MISS" ] && ok "M4 --print imports each of the $NFRAG fragments" || bad "M4 --print does not import:$MISS"

echo "retention-moves.bh-8407: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
