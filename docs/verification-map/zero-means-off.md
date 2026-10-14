# Zero means off (the pause knob, and the cap that backstops it)

**What it is:** two `off` switches on the hub's LLM lanes that did not switch
anything off. One is the session cap an operator sets to pause a lane
(`TRIAGE_MAX_FAMILIES`, `MEDIC_MAX_FAMILIES`); the other is the daily dollar cap
that is supposed to catch it when it does not (`bin/lib/lane-caps.sh` over
`catalog/lane-caps.conf`).

## The five hours this is

2026-09-20, hub, immediately after BH-1039 deployed. `TRIAGE_MAX_FAMILIES=0` was
the operator pause applied at 12:30Z, and from 12:30 to 16:10 it held — "deferred
488 families — session cap (0)", zero cost rows. After 16:10 every \*/10 tick
logged all three of these at once:

```
triage pass: 1 of 1037 line(s) across 1 famil(ies) — one session each
triage pass: deferred 659 families to next tick — session cap (0)
triage session [family …, 1 line(s), tier=strong]: handled=0 escalated=0 noise=1
```

One bought session per tick at ~$2–4, **11 rows and $38 in two hours**, every one
of them `noise=1`. The splitter reads its cap as `cap = max(1, int(capstr))`, so
a cap of 0 is clamped **up** to 1 and the first family of every tick crosses.
Nothing was broken in a way a log could show — the lane log says "session cap
(0)" on the line under the one that bought the session.

It was finally stopped at 21:20Z by `lane_day_cap_tripped alert-triage`, on
`LANE_CAPS_DEFAULT_USD=200` — because that box had the **library** but not
`catalog/lane-caps.conf` (fleet-sync lands them separately), so the reviewed
`lane alert-triage 120` row never applied. A fallback for the box that is
furthest behind was the loosest number in the file.

## What changed

| | before | after |
|---|---|---|
| `TRIAGE_MAX_FAMILIES=0` | one session per tick, forever | exits before any collection, `$0` |
| `TRIAGE_MAX_FAMILIES=-1` | clamped up to 1 | off |
| `TRIAGE_MAX_FAMILIES=off` | `int()` raised, the batch re-spooled every tick and nothing was ever triaged | ignored and **named**; the default (4) stands |
| `MEDIC_MAX_FAMILIES` | identical `max(1, …)` clamp | identical guard, before the groom and the fetch |
| built-in `LANE_CAPS_DEFAULT_USD` | `200` | `50`, and `lane_cap_usd` says in `logs/lane-caps.log` whenever the fallback is what binds |
| `lane alert-triage` | `120` | `5` |
| `LANE_USD_CAP_<LANE>=0` | refused as "not a positive number" → took the default and kept spending | binds as 0 → the lane is stopped |

## Both stops are BEFORE the lane consumes anything

The zero-cap guard sits next to the dollar-cap guard, above `WORK=$(mktemp)`,
for the same reason that one does: the collector **drains**
`state/alert-quarantine.jsonl` on the hub and on every box in `fleet.conf`, so a
check after it would have to spool the whole batch back to stay honest. Checked
here, nothing is read, no box is reached, and every alert — quarantined or
already on `state/alert-triage-deferred.tsv` — is exactly where the operator
left it. Each box's own `bin/alert-flush.sh` dead-man still escalates at 45
minutes, so a long pause stays visible. The medic's guard is above the groom and
the `/api/alerts/open` fetch; the console is its queue and re-offers oldest-first.

**Neither stop pages.** A pause is a setting, not a fault, and at \*/10 a page
per tick is 144 a day — which is how a real one gets missed. One line in the
lane's own log, every tick, naming the knob that has to change to resume. (The
DOLLAR cap does page, once per lane per UTC day: nobody chose that one.)

## `0` and `off` are opposites, and neither is "the default"

- `0` — spend nothing / run nothing. The lane is **stopped**. `zero_means: "off"`
  is how the lanes registry (BH-1132) says this about every knob, and
  `lane_caps_knobs <lane>` emits those rows **from the library that owns the
  numbers**, with the cap that is resolved right now as the `default` — so a
  settings page can never show $200 while the lane runs on $50.
- `off` (dollar cap only) — deliberately **uncapped**.
- Anything else that is not a number is IGNORED and named in the lane log. An
  operator typo may not silently remove a bound, and it may not silently remove
  the de-noising layer either. `.` and `..` are refused for the same reason now
  that `0` binds: `awk` reads them as 0, and a cap has to be written, not implied.

## Why alert-triage is $5/day and not $120

$120 was ~2x the $39–$61/day this lane ran at **before** BH-1039 — and that
baseline was itself ~150 sessions a day concluding `handled=0 escalated=0
noise=1`. Deterministic settlement, the fix-PR brake and the cliff refusal exist
so that work never reaches a model, so a cap sized to the old number would not
bind on any day short of another incident. $5 is the operator's own 21:45Z
setting.

A cap that is too LOW fails loudly and reversibly: the lane stops for the rest of
the UTC day, one page names the spend, the cap, the conf file and the
`LANE_USD_CAP_<LANE>=off` release valve, and nothing is dropped. A cap that is
too HIGH fails as a four-figure bill nobody sees until it arrives. Raise the row
when a real day trips it.

## What is NOT in this entry

The per-day **noise budget** — part (3) of #1164, the bound that stops a lane
whose sessions all conclude `handled=0 escalated=0` well before the dollar cap
does. It shipped in BH-1168 as `lane_noise_cap` / `lane_noise_record` /
`lane_noise_cap_tripped` in the same library, over the `noise` rows of
`catalog/lane-caps.conf` and `LANE_NOISE_CAP_<LANE>`, and it reads `0` and `off`
exactly the way this entry describes. It lives in
[lane-volume-caps.md](lane-volume-caps.md), with
`tests/triage-noise-budget.bh-1168-test.sh` driving it.

## How to drive it

```
tests/triage-session-cap-zero.bh-1164-test.sh   the real bin/alert-triage.sh and
                                                bin/alerts-medic.sh at cap 0, and
                                                the caps library's defaults/knobs
tests/triage-volume-caps.bh-1039-test.sh        the lane at a POSITIVE cap, unchanged
tests/lane-caps.bh-1039-test.sh                 the conf grammar and the day total
```

On a live hub: `logs/alert-triage.log` shows
`STOPPED — TRIAGE_MAX_FAMILIES=0 means zero sessions` once per tick with no cost
rows behind it, and `logs/lane-caps.log` shows
`no lane-caps.conf on this box — capped at $50/day by the built-in defaults`
once a day on any box whose sync has not landed `catalog/lane-caps.conf`.
