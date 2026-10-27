# Retention rules compose from retention.d/ fragments (BH-8406, BH-8398.0)

Doc: worker/jobs/README.md

## Why

`worker/jobs/src/routes/retention.js` had 10 replayed merge conflicts in 30
days. Each one came from two builds that appended a rule to the end of the
same `RULES` literal.

## What changed

- A rule can now live in its own file:
  `worker/jobs/src/routes/retention.d/bh-<n>[.<m>]-<name>.js`, whose default
  export is an array of rules. The first one is
  `bh-7598-web-task-human-step.js`. It holds the `web_task_human_step.age`
  rule, moved byte for byte from the end of the literal.
- `worker/jobs/src/lib/retention-rules.js` is the pure composer:
  `fragmentNames` (refuses a `.js`-like name that is not a fragment, sorts by
  the numeric ticket key, then the name), `checkRules` (refuses a missing or
  non-string `rule`/`table`/`key`/`ids`/`del`, a non-integer `def`, a
  duplicate `rule`) and `renderRulesModule`.
- `#retention-rules` (`worker/jobs/package.json` imports): under wrangler
  (`workerd`) it is the git-ignored render `src/retention-rules.gen.js`. Under
  node (`default`) it is `src/lib/retention-rules.node.js`, which reads
  `retention.d/` at load time.
- `worker/jobs/scripts/retention-build.mjs` writes the render (`--print`,
  `--out <path>`). `wrangler.jsonc` `build.command` runs it after
  `routes-build.mjs` and `core-registries-build.mjs`. A bad fragment fails the
  build step with one `retention-build: <message>` line and writes no file.
- `retention.js` keeps the other rules in a private `INLINE_RULES` list and
  exports `RULES = checkRules([...INLINE_RULES, ...FRAGMENT_RULES])`. The
  names, the count (48) and the order of `RULES` are the same as before.
  BH-8398.1 moves the rest of the inline rules.

## Where a new rule goes

Add a new file in `retention.d/`, keyed by your ticket. Never append to
`INLINE_RULES`. A fragment imports only from `../../lib/`, never from
`retention.js` (that is an import cycle). A rule name that already exists
fails the worker load and the build step.

## Verify

`HARNESS_TEST_SANDBOX=1 bash tests/retention-split.bh-8398-test.sh`
