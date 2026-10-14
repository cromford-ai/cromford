# BH-1512: a zero-byte resolver record is counted and named, not dropped

Doc: resolver-prepass

## What was broken

`br_record_index` (`bin/blocked-resolver.sh`) turns every
`state/blocked-resolver/<project>/<key>.json` into one indexed row. It reads the
tree with

```
find … -type f -print0 | xargs -0 -r awk 'FNR==1 { printf "%s\t%s\n", FILENAME, $0 }' | jq …
```

awk runs its rule on RECORDS. A zero-byte file contributes no record, so `FNR==1`
never fires for it and no `<path>\t<payload>` line is emitted. The record never
reached `jq`, which meant it never became the `!PARSE` row BH-1457 built for
exactly this case: `br_prepass` never counted it into `$bad`, the one
"N state record(s) could not be parsed and were not indexed" line never mentioned
it, and the tick line carried no `+index-short`. The operator read a clean tick
while a record was missing from the index.

That is the last silent degradation in this pre-pass, and it is not a theoretical
one: every record write in this lane is a non-atomic `printf > "$f"`, and a
zero-byte file is precisely what an interrupted one leaves behind. A `not json`
record — the same failure with one more byte in it — was already loud.

## What changed

One hunk, in `br_record_index` only. The `find | xargs awk` pipeline head became
a brace group that feeds the SAME `jq` from two walks:

- the existing walk, unchanged;
- `find … -type f -empty -printf '%p\t\n'`, which emits a zero-byte record as
  `<path>\t` — a payload jq's existing `try fromjson catch null` turns into
  `null`, i.e. the same `!PARSE` row a `not json` record gets.

Nothing else moved. The jq program, the `!PARSE` arm, the `$bad` count in
`br_prepass` and the log line are untouched: an empty record is counted INTO the
existing total, named on the SAME single line, and marked with the SAME
`+index-short` word. No new label, no new field, no second line.

The safe direction is unchanged on both sides. `!PARSE` is an outcome
`br_finished` never matches, so nothing is retired off an empty record, and a
candidate under that key is costed off zero counters. `br_load` already treats an
empty file as fresh (`[ -s "$f" ]`), so its rung is unaffected either way.

The two walks partition on `-empty`, so no record is emitted twice. A record
written BETWEEN the two walks can be: the index is an associative array, the last
row wins, that key reads `!PARSE` for one tick (counted, marked, nothing retired)
and heals on the next. The other order drops it for one tick, which is exactly
today's behaviour. The window is microseconds per record and is documented in the
code rather than engineered around — making record writes atomic is a different
ticket, and this change is what makes the moment visible at all.

## How to see it

On the hub, with a zero-byte file under `state/blocked-resolver/<project>/`:

```
grep -c '+index-short' /root/harness/logs/blocked-resolver.log
grep 'could not be parsed and were not indexed' /root/harness/logs/blocked-resolver.log | tail -1
```

A healthy tree counts 0. A non-zero count now means a real empty or broken record
exists, and the adjacent line says how many.

## Tests

`tests/blocked-resolver-prepass.bh-1512-test.sh` — four sections, each driving the
real lane end to end against a scratch `$HARNESS`, beside §12 of
`tests/blocked-resolver-prepass.bh-1457-test.sh` (its `not json` twin): a
zero-byte record marks the tick and writes one count line while the ABANDONED row
beside it still retires; an empty record under the candidate's own key retires
nothing and still marks the tick; a clean tree is still not marked; and an empty
record plus a `not json` record produce ONE line counting 2.
