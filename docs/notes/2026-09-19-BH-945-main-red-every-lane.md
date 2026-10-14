# The main-red freeze reaches every merge lane, from the shared flag store

Doc: MERGE-CONDUCTOR, TEST-DETERMINISM

**What happened.** `flags/main-red-example-org-cromford` went up on the hub
at 20:41Z on 2026-09-18 and `bin/merge-conductor.sh` logged
`MAIN_RED_FREEZE in force` every tick — while #931 (21:10Z) and #942 (22:42Z)
merged into that same red main through box-side lanes. Two halves were broken:

1. **The flag never left the hub.** `bin/main-red-detector.sh` wrote and removed
   a local file (`> "$FLAG"`, `rm -f "$FLAG"`) and never called `flag_set`, so
   no `pause_flags` row was ever written for it. A box asking
   `flag_active main-red-<slug>` got "no row", and its own `flags/` directory
   was empty. Boxes could not see the freeze even if they asked.
2. **Only the conductor asked.** `main_red_flag` / `main_red_test_path` /
   `main_red_exempt` were private functions of `bin/merge-conductor.sh`. The
   five other lanes that run `gh pr merge` and the two that feed them had zero
   reads of main-red between them.

**What changed.**

- **New `bin/lib/main-red-gate.sh`**, sourced from
  `bin/lib/merge-conductor-lib.sh` behind the same `command -v` guard as
  `bin/lib/block-gate.sh` (BH-762) and `bin/lib/pr-dep-gate.sh` (BH-629). It
  holds the freeze, moved out of the conductor under the same names — so the
  conductor's two call sites did not change — plus `mrg_flag_on` (the
  conductor's `flag_on`, spelled once, which reads through `flag_active` so a
  box materialises the flag from the row) and `main_red_hold`, the rc contract
  the lanes call: **0 = HOLD, 1 = proceed**, with the flag name left in
  `MRG_FLAG`. Zero GitHub calls when no flag is on; one
  `gh pr view --json headRefOid,labels` per non-exempt PR while one is.
  `main_red_flag` memoises per `(project, slug)` for the life of the process.
- **The detector publishes.** `mr_publish` = `flag_set` when
  `bin/jobs-client.sh` is loaded, else a no-op. It is called on all four
  decisions — newly red, new sha, **still red on the same sha**, and green —
  always in the order **file → row → alert**, so the hub is correct even if the
  PUT dies and the next red tick republishes it. `flag_set` only `touch`/`rm`s
  the file, so the flag BODY (`sha=`/`workflow=`/`job=`/`since=`/`reason=`) the
  conductor's `MAIN_RED_WHY` line reads is untouched. `mr_publish` returns
  `flag_set`'s rc and keeps `state/main-red/<name>.published` while the row is
  known to be ON (written on a landed `on`, removed on a landed `off`), so a
  green tick with no flag file but a marker republishes `active:0` until it
  lands. Without that the OFF side did not self-heal: a clear whose PUT died
  left every box frozen until a hand ran `flag_set … off` (§ D5).
- **Seven lanes ask, immediately before their write.** On a hold each one logs
  exactly one line, writes nothing to GitHub, and `continue`s:

  | lane | where | on HOLD |
  |---|---|---|
  | `bin/merge-queue.sh` | `mr_queue_hold` (`# >>> main-red gate`), called at all three landing paths — union assembly, train landing, serial | entry stays queued, never `.blocked`, no `MQROW`, no beat |
  | `bin/merge-sweep.sh` (hub) | `# >>> main-red gate`, after the dep gate, before `sweep_claim`; the project is resolved from `fleet.conf` for the PR's slug, so both flag spellings hold here too | not claimed, not `sweep_record`ed — a recorded park is invisible for ever |
  | `bin/review-prs.sh` | `hold_main_red`, a new `elif` in `merge_step` after `bg_review_hold`; `merge_retry` holds silently next to `hold_automerge_disabled`, so a frozen tick is not a spent attempt | `MERGED=no`, so the approved-head retry re-asks next tick with its `REVIEW_MERGE_RETRY_MAX` budget intact |
  | `bin/tier2-merge-sweep.sh` | `# >>> main-red gate`, after the batch-hold gate and the native-queue stand-down | not enqueued; re-offered every sweep |
  | `bin/batch-resolve.sh` | next to `flags/batch-resolve-off`, setting the script's own `GATED`/`GATE` | no NEW train; a train already pushed is still settled |
  | `bin/run-build.sh` tier-1 | after the dep-gate block, inside `# >>> tier-1 merge gate` | `CONDUCTOR_OWNS_MERGES=1`, exits through `PR_CREATED` |
  | `bin/merge-conductor.sh` | unchanged — `:1963` READY arm, `:2223` project tick | unchanged |

  `bin/poll-commands.sh` is deliberately outside the gate: a `merge_pr` command
  is a human at Mission Control, and iron guardrail 1 exempts it by name.
  `bin/review-autopilot.sh` never merges.

**Two decisions worth stating.** The gate **fails closed on the exemption read**
(a diff nobody can read is not test-only) and **fails open on the flag read** (a
worker outage with no local file is "no flag", which is `automerge-disabled`'s
own rule — a fleet that stops merging during every worker blip is a stall
nobody asked for). And the freeze is a repo FACT, not an operator knob: the
detector's per-tick republish bumps `updated_at`, so a flag an operator `rm`'d
by hand comes back within a tick. `automerge-disabled` is the knob, and it is
untouched.

**Knobs.** `MC_MAIN_RED_LABEL` [`fix-main-red`] and `MC_MAIN_RED_TEST_PATHS`
[`tests/* worker/*/test/*`] keep their names and are now read fleet-wide rather
than only by the conductor. Both are documented in
`env-templates/global.env.example`. No new kill switch, and note that
`flag_set main-red-<slug> off` (or the console) on its own does NOT unfreeze
the fleet while main is red: the detector's per-tick republish re-raises the
row within 5 minutes, and on the hub the console's newer `active:0` row makes
`flag_sync` remove the hub's flag file, so the next tick takes the "newly red"
branch and pages a second critical alert. The only lever is to stop detection
first (`MAIN_RED_DETECT=0` or `flags/main-red-detector-off`) and THEN
`flag_set main-red-<slug> off`. Turning detection back on re-raises the freeze
if main is still red, which is the point.

**Tests.** `tests/main-red-box-freeze.bh-945-test.sh` — the detector's publish
against a recording `curl`, every lane against a raised flag, both exemptions,
and the adversarial negatives (`fix-main-red-later` does not exempt,
`tests/a-test.sh` + `bin/b.sh` does not, an unreadable file list does not, a
flag for another repo does not hold, a `active:0` row clears a stale local
file, an outage with no file does not hold).
