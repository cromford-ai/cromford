# Pre-plan cadence gate runs before the stale re-plan (BH-2998, BH-2992.4)

Doc: EVENTS

## The old order

In the speculative loop of `bin/preplan-tick.sh`, a key with a stale plan on disk
went through `preplan_replan_allow` first. On allow that call writes a stamp to
`state/preplan/<p>-<k>.replans`, and the tick then logged `PREPLAN_STALE` and
deleted `plans/<p>-<k>`. Only after that did the `# >>> preplan cadence (BH-2543)`
block ask `preplan_cadence_allow`. A cadence deny `continue`d with nothing
launched.

## The waste

Every cadence deny on a stale key burnt one unit of `PREPLAN_STALE_MAX` and threw
away a plan the build stage could have adopted or discarded for free. The next
tick then saw a missing plan and, once cadence allowed, bought a fresh one.

## The new order

1. `if [ -s "$D/plan.md" ]` runs `preplan_check`. A fresh plan `continue`s; a
   stale one sets `PP_STALE=1`.
2. The cadence block, text and markers unchanged.
3. Only when `PP_STALE=1`: `preplan_replan_allow` (cap line + `continue` on
   deny), then the `PREPLAN_STALE` line and the drop.
4. The launch.

A cadence deny now writes nothing: the plan stays, `.replans` gets no line, no
`PREPLAN_STALE` is logged. `FREE`/`PREPLAN_PARALLEL` accounting is unchanged
because a deny still only `continue`s.

## Why cadence sits after the fresh-plan continue

`preplan_cadence_allow` stamps `state/preplan/cadence-<p>.last` on allow. Asked
before the fresh-plan `continue`, every fresh-plan key in a cut project would use
up the project's interval with nothing launched.

One accepted cost: in a cut project, cadence can allow (and stamp) and the
re-plan cap can then deny. That spends up to one interval of latency, no money.
Avoiding it would need a non-stamping cadence peek, a lib change this slice
does not make.

Pinned by `tests/preplan-cadence-order.bh-2992-test.sh` (O1-O4, O4 moves the
block back and must go red).
