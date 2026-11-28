# 2026-11-12 — BH-9453: the missed-webhook sweep of the gh shim cache

Doc: GH-REST

## What changed

- New hub lane `bin/gh-cache-sweep.sh` (cron `cron/lanes/713-gh-cache-sweep.cron`,
  every 5 minutes; a sweep runs once per `GH_CACHE_SWEEP_PERIOD_S`, default 900 s).
  For each registry repo it reads the open PRs and the issues updated since the
  last sweep, and compares them with its record `state/gh-cache-sweep/<repo>.tsv`.
  For each changed object it drops `<repo>~n-<N>~*` and the old and new head's
  `<repo>~s-<sha12>~*` shim cache entries, and once per repo `<repo>~r~*`.
  After a complete read it writes the record, then the stamp
  `state/gh-cache-sweep/<repo>.stamp` (`v3 <sweep_start> <chain_start> <period_s> <base> <end> <trust_periods>`). `<end>` is the
  time the sweep finished its reads and drops; `<base>` is the previous stamp's
  `<end>` (a restart: its own `<end>`).
  A failed read drops and writes nothing for that repo.
- `ghc_sweep_covers` (`bin/lib/gh-cache-sweep.sh`) reads the stamp. It vouches
  for an `n-<N>` entry, and for a `<repo>~r` entry, when a fresh sweep (younger
  than `<trust_periods>` periods, knob `GH_CACHE_SWEEP_TRUST_PERIODS`, default 2) started after the entry was fetched, the chain began at or
  before the fetch, and the fetch came after `<base>` (a fetch made while the
  previous sweep was still reading, or stored after its drop, is not covered). An `r` entry also must be younger than the repo's last list drop.
  An `s-<sha12>` entry is never covered: a commit status changes with no change
  the sweep can see. The bare PR read `repos/<o>/<r>/pulls/<N>` is never served
  on sweep coverage either (`ghc_sweep_covers` checks `GHC_LPATH`, the bare path `ghc_main` set): its `mergeable_state`
  changes with no `updated_at` or head change, so it keeps the
  `GH_CACHE_EVENT_MAX_S` bound (lead review of #9597).
- `bin/lib/gh-cache.sh`: `ghc_main` also takes a repo's `pulls` or `issues`
  list, or `search/issues` (tag `<repo>~r`), into the event branch. Such an
  entry is served `cache` only while `ghc_sweep_covers` vouches for it, never on
  its age alone. `ghc_drop` writes `.rdrop.<repo>` (or `.rdrop._all` for the seed
  drop) before it drops a repo's lists.
- Knobs (settings rows `lane.gh-cache-sweep.*`): `GH_CACHE_SWEEP` (0: ships off until a rework trusts the BH-9939 prr-sweep stamp, because its open-PR list read doubles that lane's),
  `GH_CACHE_SWEEP_PERIOD_S` (900), `GH_CACHE_SWEEP_OVERLAP_S` (120),
  `GH_CACHE_SWEEP_MAX_PAGES` (20), `GH_CACHE_SWEEP_TRUST_PERIODS` (2).

## Check

`tail -n 3 /root/harness/logs/gh-cache-sweep.log`: one
`repos=<n> rows=<n> changed=<n> unreadable=<n> requests=<n>` line a run.
