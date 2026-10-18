# tests/fixtures/break-it.bh-6970

Fixture model answers for `tests/break-it.bh-6970-test.sh` (BH-6970). Each file
is what the stub `bin/agent-call.sh` writes as the break-it call's answer. The
suite builds the repo they run against (`bin/greet.sh` that prints `hello <name>`,
and `worker/jobs/src/add.js`) in its scratch dir.

- `three-cases.txt`: prose and a fenced JSON object; 3 shell cases, the 2nd fails.
- `all-pass.txt`: 3 shell cases that all pass.
- `six-cases.txt`: 6 passing shell cases (only `break_it.max_tests` are kept).
- `short-run.txt`: the 3rd case stops the run, so 2 result lines for 3 cases.
- `zero-cases.txt`, `garbage.txt`: no usable case.
- `node-cases.txt`: 2 node cases on `../src/add.js`, the 2nd fails.
- `node-bad-import.txt`, `node-climb-import.txt`: imports outside `node:` and `../src/`.
