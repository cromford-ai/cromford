# The gh shim cache serves PR- and sha-scoped entries past the TTL while wakes are healthy (BH-9451)

Doc: GH-REST

## What changed

BH-9451 is part 1 of 5 of BH-9417. Before it, every `gh api` GET entry past
`GH_CACHE_TTL_S` (60 s) cost one conditional request, even when no webhook
wake said the object changed.

`bin/lib/gh-cache.sh` `ghc_main` now serves an entry past the TTL from
`state/gh-cache/` with no request when all of these are true:

- `GH_CACHE_EVENT_MAX_S` is above 0 (settings row
  `lib.gh-ledger.gh_cache_event_max_s`, default 300, code fallback 300).
- The entry's tag is `n-<N>` (pulls/issues) or `s-<sha12>` (commits/statuses).
  The `r` tag (lists, search, other paths) keeps the conditional request.
- `ghc_wake_sync` returned 0 and `state/gh-cache/.wake-down` does not exist.
  The sync drops the entries of every object a wake names before the decision.
- The entry is at most `GH_CACHE_EVENT_MAX_S` old, or `ghc_sweep_covers`
  returns 0.

Every other case keeps the BH-8066 path. A feed that is down, or a busy sync
lock, gives a conditional request. `GH_CACHE_EVENT_MAX_S=0` restores the BH-8066
call sequence. The ledger row of a served entry says `served=cache`.

## Seams

Three seam files sit beside `gh-cache.sh`. `gh-cache.sh` defines the same
defaults inline first, so a box without a file behaves the same.

- `bin/lib/gh-cache-scope.sh` (BH-9417.2): `ghc_scope_tag`, `ghc_wake_drop`.
- `bin/lib/gh-cache-sweep.sh` (BH-9417.3): `ghc_sweep_covers`, rc 1 by default.
- `bin/lib/gh-cache-eligible.sh` (BH-9417.4): `ghc_path_ok`, the BH-8066 refusal list.

Wake rows are now read as `id repo kind key`, and each drop (wake or a write
on this box) goes through `ghc_wake_drop`.

## Formats

`state/gh-cache/.knobs` is `ttl grace at event_max`. A 3-field line from older
code reads as event_max unset, so the fallback applies.

## Tests

`tests/gh-cache-event-valid.bh-9451-test.sh`. `tests/gh-shim-cache.bh-8066-test.sh`
pins `GH_CACHE_EVENT_MAX_S=0`, the knob-off path.
