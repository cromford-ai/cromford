# A PR the merge queue ejected twice gets its fix round now, with the two failing batch runs (BH-6000 part 5)

Doc: MERGE-CONDUCTOR

## What happened

On 2026-10-11, #4624, #5459, #5697 and #5920 were parked `queue-ejected-twice` with no time bound. They waited
for the blocked-resolver's next pass. Its first rung (merge main, re-run the PR's own CI) answers nothing about a
batch build that is red against current main, and the fix round that could answer it never saw the failing runs.

## What changed

1. **The conductor hands over at once** (`mc_eject_fix_now`, `bin/lib/mc/queue.sh`). On the second ejection,
   once per (PR, head), the conductor does three things:
   - it reads the last two Mergify dequeues' failing batch runs (`bej_eject_runs`, `bin/lib/mc-batch-eject.sh`,
     one REST read);
   - it writes them to `state/merge-conductor/eject-runs/<key>`, with the head on line 1;
   - it starts `BR_ONLY_PR=<key> blocked-resolver.sh <project>` detached, in the same tick.

   Observe mode writes and starts nothing.
2. **The resolver works that one PR** (`# >>> one-PR run`, `bin/blocked-resolver.sh`). With `BR_ONLY_PR` set,
   the run keeps only that PR's rows. Its per-key and per-project locks still apply.
3. **The fix round comes first** (`# >>> ejected twice: fix round first`). When the runs file exists, a
   `queue-ejected-twice` park skips rung 1 and the regenerate rung and goes to the fix round, while fix rounds
   are left.
4. **The brief carries the runs** (`# >>> eject runs brief`). The fix-round brief lists both failing batch runs
   (each run URL with its check, draft and dequeue time).

## Operating

- Conductor log: `queue-ejected-twice — bin/blocked-resolver.sh started for this PR now (BR_ONLY_PR), its fix
  round handed N failing batch run(s)`.
- Resolver log: `one-PR run for <key>: …` and `straight to the fix round`.
- If a resolver run of the same project is already scanning, the one-PR run is turned away by its lock, and the
  scanning run takes the park.
