# The ticket-key cache: a key `br_one` paid for is carried beside the row

Doc: MERGE-CONDUCTOR

**What changed.** BH-487 order 3 of 3. The two `br_tkey_*` stubs the contract
slice (BH-946) put in `bin/lib/rebuild-ledger.sh` now have bodies, plus one
internal helper. No other file in `bin/` changes: the call sites were placed by
the contract — `br_one` puts the key it derived, `br_conductor_emit` passes
every discovered key through the sync.

- `br_cached_tkey <project> <rkey>` — the cached key, or rc 1. Reads
  `$ST/<project>/<rkey>.tkey`, takes its FIRST line and runs it through
  `br_key_shape`; absent, empty or wrong-shaped answers rc 1.
- `br_tkey_put <project> <rkey> <key>` — writes the key, one line, to that path.
  An empty or `-` key writes nothing and answers rc 0.
- `br_tkey_sync <project> <rkey> <derived-key>` — prints the key discovery
  carries. No derived key: the cache if it is still a key, else `-`. A derived
  key: itself, and a cache that DISAGREES is overwritten on that tick.

**Why.** Discovery (`br_conductor_emit`) asks gh for the head branch before
`br_one` installs the repo's installation token, so on a repo the default token
cannot see the branch comes back empty and the candidate arrives keyless.
`br_one` re-derives it inside the token — two `gh pr view` reads — and logs
`discovery carried no ticket key — derived <KEY> from the PR/record`. Every ten
minutes, for the life of the park. The cache is the persisted "already derived?"
answer, keyed on the stable `<project>/<rkey>`, read before the two reads are
spent.

**gh always wins.** The cache is written from whatever source answered, often a
PR title; a later tick where gh itself names the branch is better evidence, so a
disagreeing cache is rewritten and the tick acts on the gh key. An identical
cache is compared and left alone — this runs on every park on every tick, and a
write per tick is churn nobody asked for. While gh stays blind for a park the
stale cache IS acted on: it only dies on the tick gh answered, which is the
trade the ticket asks for.

**The shape is the whole guard.** A cached line counts only if it still passes
`br_key_shape`, the guard every other key source passes through. A hand-edited
`not a key` is ignored — the tick behaves exactly as it did before BH-487 (the
row lands under the PR-number rkey, the enqueue is refused, `.nokey-alerted`
pages once) — and the file is left as written, because nothing overwrites it
until gh answers. `TK-9` comes back `TK-9`; `TK-9: nav anchors` comes back
`TK-9`.

**Why not a `*.json`.** `br_from_rebuilds` globs `"$ST"/*/*.json` to find rows
with a rebuild in flight. A cache file under that glob would be read as a state
row. `.tkey` is a sibling of the `.nokey-alerted` marker, in the same directory,
outside that glob.

**Why sync never creates.** Only `br_one` knows a key was DERIVED — discovery
may simply have been handed one by the branch, which costs nothing to read
again. So the sync writes only when it is correcting a file that already exists;
a park that never reached `br_one` keeps no cache. That also keeps the write
path to one function when asking "who made this file".

**What it touches.**

- State: `state/blocked-resolver/<project>/<rkey>.tkey`, one line, the shaped
  ticket key. Nothing reads it but `br_tkey_sync`; nothing writes it but
  `br_tkey_put` and the sync's overwrite arm.
- Knobs: none. No new `BR_*` env var, no cron change, no migration.
- No `gh`, no `date`, no network in the lib, and no `${HARNESS:-…}` default —
  `$ST` and `br_key_shape` are the resolver's and bind at call time
  (`tests/no-harness-export-test.sh` section D copies this lib and rewrites its
  root).

**How it is pinned.** `tests/blocked-resolver.bh-948-test.sh` (new): an
in-process table over the resolver's own extracted `br_key_shape`, then three
end-to-end runs of the real `bin/blocked-resolver.sh` in act mode from a scratch
`$HARNESS`. `tests/rebuild-ledger.bh-946-test.sh` section 6 was written to
assert the STUBS wrote nothing; it now asserts the put writes exactly one file
and the sync answers `-` for a park with no cache. Nothing else in that suite
moved, and its count is unchanged at 66.
