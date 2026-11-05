# Public checkout build and test preparation

The public checkout must build and exercise its authorization rules without
private workflows or generated files copied from an operator machine.

The dashboard's hyphenated actor keys are quoted. Affected test modules now
use legal JavaScript identifiers while retaining the hyphenated project values
they exercise. Fly token environment names in shell fixtures use the existing
`fly_token_resolve` normalization (`project-5` becomes `FLY_API_TOKEN_PROJECT_5`).

Several existing test assertions were inconsistent with the published example
data. Repairs retain the original strict assertions: distinct account/repo
fixtures remain distinct, alphabetical results follow the example names,
email expressions match the fixture email, invalid reviewer names remain
invalid, and boundary cases still exercise exactly 65-character setting keys
and 2049-character input. The unblock seed test now recognizes that an earlier
`off` seed is preserved by `INSERT OR IGNORE` and checks SQL statements rather
than rejecting a project name used only in a comment. No tests are skipped or
assertions loosened to make CI pass.

`.node-version` supplies the exact supported Node release to `setup-node` and
the local Linux image resolver. The image no longer reads the unpublished
`harness-ci.yml`. An explicit Node override or reachable bake settings row may
still select a release in the same major; a different major is refused.

Jobs and OTP `npm test` run `bin/test-worker-bootstrap.sh` first. It recomposes
the lane and LLM-site catalogs from committed fragments every time, so a fresh
checkout and a changed fragment both reach the tests without stale output.
Direct consumers of the jobs worker should run that bootstrap explicitly.

Every PR now runs JavaScript syntax validation, the dashboard production build,
all six Node package suites, a security regression matrix, dependency audits
and focused shell regressions. Weekly and manually dispatched jobs shard the
larger Linux shell corpus. Test failures retain nonzero exit statuses.

The dashboard uses Vite 6.4.5 and source-map-js 1.2.2, resolving the audited
toolchain advisories while remaining on Vite's supported 6.4 patch line.

QA preview login accepts `QA_PREVIEW_DOMAIN` as a trusted deployment binding,
defaulting to the documented `console.example.pages.dev` example. Only a
single branch alias beneath that domain may sign in; production root, `main`,
deployment hashes, nested aliases and unrelated domains remain refused.
