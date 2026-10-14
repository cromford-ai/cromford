# BH-1281: the main-red STREAK arm no longer re-raises a freeze on top of a re-test

**The fight between two lanes.** `bin/main-red-detector.sh` has two arms. The
TIP arm already waits when a newer run of the same workflow has not concluded
(`newest_any` vs `newest` in the python verdict block): a re-run in flight means
the evidence is being replaced, and freezing on top of it is how a flake stops
the fleet. The STREAK arm read completed runs only and knew nothing about a run
in flight.

BH-1269 gave `bin/batch-resolve.sh` the ability to lift `flags/main-red-<repo>`
the moment a `fix-main-red` PR merges with its merge-ref head concluded green,
instead of waiting for the detector's next pass over main (~20 minutes; three
episodes' worth of fleet-wide merge stop in one day bought that ticket). In a
single-red episode the tip arm's suppression means the lift holds while the
fix's own run on main finishes.

In a MULTI-red episode — the "STILL RED on a new sha" shape, a first fix that
did not fix — the two lanes fought:

1. main is red on two consecutive completed runs, so the streak arm raised the
   flag;
2. a `fix-main-red` PR merges with its merge-ref run green, and batch-resolve
   clears the flag and the D1 `pause_flags` row;
3. the fix's own run on main is still in flight, so the detector's next tick
   still sees the same two completed reds, re-raises the flag with a fresh
   CRITICAL page, and **rewrites the flag file**, which gives it a new mtime;
4. `mrt_main_red_fixed`'s lower bound for "has a fix merged since the freeze
   went up" is that mtime, so the fix that just merged is now excluded and the
   lift can never happen again.

Net: the freeze stood until the fix's main run completed anyway (the
pre-BH-1269 behaviour, so nothing was broken) plus one spurious CRITICAL page
per episode — and BH-1269's saving was silently lost in exactly the episodes
that last longest.

**The fix, and why it is narrowed to raising.** The verdict block gains an
eleventh tab column: the sha of a run of that workflow NEWER than the newest
completed-evidence run whose `status` is in an allow-list
(`queued`/`in_progress`/`waiting`/`pending`/`requested`), empty otherwise. The
bash streak filter then splits on `[ -f "$FLAG" ]`:

- **flag on disk** — the filter is byte-for-byte what it has always been. The
  still-red republish, the new-sha notice and the green clear all keep judging
  an open episode on completed evidence alone.
- **no flag** — the filter additionally requires column 11 empty, and a second
  `awk` captures the held row so the tick can say why it did not raise.

A blanket hold would have been wrong, not merely wider: with a flag on disk and
a green sibling workflow it drops into the CLEAR branch and lifts a freeze that
a red streak still justifies. Every path that starts with a flag on disk is
therefore untouched.

**The allow-list, not "anything that is not completed".** A run whose `status`
field is missing or a word GitHub has not shipped yet decides nothing — the same
rule the `epoch()` helper next to it already follows. `cancelled` and `skipped`
runs ARE completed, so they are never in flight: they stay exactly what the
streak contract already said they were, not evidence, and they neither break a
streak nor hold one.

**A held tick is not a green main.** It used to log
`main green (0 required workflow(s))`, which is the one log an operator reads to
find out why no freeze went up, and it was false. It now names the workflow, the
streak and the sha being re-tested. The held tick sends nothing, publishes
nothing, and makes NO jobs read (that read lives inside the raise branch), so it
is strictly fewer side effects than before.

**One more thing the diff carries.** `IFS=$'\t' read … REPOCH` now ends in a
trailing `_`. `read` assigns the rest of the line to its last variable, so
without it REPOCH would swallow column 11 and the tip arm's
`(NOW - REPOCH) / 60` would be arithmetic on `<epoch><tab><sha>`.

**What it touches:** `bin/main-red-detector.sh` only — `bin/batch-resolve.sh`
and `bin/lib/mc/train.sh` are correct once the detector stops rewriting the
flag, and the seven `flags/main-red-<repo>` readers test the file's presence
only, so a tick that writes nothing reaches none of them differently. Pinned by
`tests/main-red-detector.bh-1281-test.sh` (R1/R1q hold, C1 raises as today,
N1/N2/N3 hold nothing, F1 leaves a standing flag byte-identical, E1 keeps
`--explain` read-only, G1 keeps the real `main green` line).

**Still true after this change:** once the held run CONCLUDES red, the next tick
sees a streak of three with no flag on disk and raises a fresh CRITICAL. That is
BH-1269's episode semantics — a lift ends the episode — not a regression here.

Doc: TEST-DETERMINISM
