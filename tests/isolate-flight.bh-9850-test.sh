#!/bin/bash
# tests/isolate-flight.bh-9850-test.sh — the jobs worker's per-isolate
# single-flight keeps plain values only (BH-9850).
#
#   (a) a waiter whose creator never settles runs its own work after the poll budget
#   (b) concurrent callers share one run when it settles in time
#   (c) a slot never holds a thenable
#   (d) flightKnobs ignores out-of-range values (fallback 3000 / 20)
# The route-level cases (worker.fetch, ensureTable, settingsRows) are in
# worker/jobs/test/cross-request-promise.bh-9850.test.js.
# Run from anywhere: bash tests/isolate-flight.bh-9850-test.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
H="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$H/worker/jobs/src/lib/isolate-flight.js"
[ -f "$SRC" ] || { echo "FAIL: $SRC missing"; exit 1; }
command -v node >/dev/null || { echo "SKIP: node not installed"; exit 0; }
out=$(cd "$T" && node --input-type=module -e '
const m = await import(process.argv[1]);
const never = () => new Promise(() => {});
const r = [];
const s1 = new Map();
m.isolateFlight(s1, "k", never, { waitMs: 40, pollMs: 5 });
r.push("a=" + await m.isolateFlight(s1, "k", async () => "own", { waitMs: 40, pollMs: 5 }));
const s2 = new Map(); let runs = 0;
const slow = async () => { runs++; await new Promise((x) => setTimeout(x, 15)); return "shared"; };
const both = await Promise.all([m.isolateFlight(s2, "k", slow, { waitMs: 500, pollMs: 5 }), m.isolateFlight(s2, "k", slow, { waitMs: 500, pollMs: 5 })]);
r.push("b=" + both.join(",") + ":" + runs);
const thenable = [...s1.values(), ...s2.values()].some((v) => Object.values(v).some((x) => x && typeof x.then === "function"));
r.push("c=" + thenable);
const k = m.flightKnobs((_d, key) => ({ "d1_flight.wait_ms": "9000", "d1_flight.poll_ms": "1" })[key], {});
r.push("d=" + k.waitMs + "/" + k.pollMs);
console.log(r.join(" "));
' "$SRC" 2>&1)
want="a=own b=shared,shared:1 c=false d=3000/20"
if [ "$out" = "$want" ]; then echo "ok   isolate-flight -> $out"; exit 0; fi
echo "FAIL isolate-flight -> $out (want $want)"
exit 1
