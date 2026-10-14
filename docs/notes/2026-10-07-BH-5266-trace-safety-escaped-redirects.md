# Trace-safety reads escaped redirects one layer down, and declare "(…)" is an interpreter (BH-5266)

Doc: CI-RUNNERS

## What changed

- `bin/test-trace-safety.sh`, `redirects()` in the awk parser: a backslash in a
  redirect target is now read the way the inner shell reads it. `\<space>`,
  `\<tab>` or a backslash before one of the existing terminators
  (`'`, `"`, `;`, `)`, `|`, `&`, `>`, `<`) ends the target. Any other `\<c>`
  is `<c>`. A trailing lone backslash is dropped.
- `is_interpreter()` now also matches `declare`, `typeset` and `local` when one
  of their operands looks like `NAME=(…`. xtrace prints
  `declare -a ARGV="($s)"` as `declare -a 'ARGV=(…)'`, and bash re-parses that
  string into words the same way eval does. `declare -a W`, a scalar
  `local x=msg` and a bare `W=(…)` still don't count.
- Header (`--help`, now lines 2-135) and `docs/verification-map/trace-safety.md`
  say both.

## Why

Batch #5259 went red on three hits from #5059. Its test ran
`CMD=$(printf '%q' …); eval "set -- $CMD"`, which xtrace prints as
`eval 'set -- stat\ -c\ %Y\ /run/x\ 2\>/dev/null\ \|\|\ echo\ 0'`. The parser
stopped the target at the escaped space and kept the backslash, so it judged
`/dev/null\`, which is not a safe device. The way around it was
`declare -a ARGV="($CMD)"`, which the gate did not read at all. Now the first
is clean and the second is read like eval.

An escaped redirect to an unsafe path is still a hit: the unescape resolves the
target, it never excuses it.

## Pinned by

`tests/test-trace-safety-escaped.bh-5266-test.sh` (E1-E4 escaped eval payloads,
D1-D4 declare/typeset/local, N1-N4 shapes that must stay clean).
