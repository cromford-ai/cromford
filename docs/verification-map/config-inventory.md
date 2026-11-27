# Config inventory

**What it is:** a static-analysis pass, not a running lane. #1511 ("every
harness setting and endpoint is a DB value") starts with a slice that changes
no behaviour: classify every `${VAR:-literal}` read in `bin/`, `fly/`,
`cron/` and every hardcoded endpoint literal in `bin/`, `fly/`,
`worker/jobs/src`, `console-ui/src`, so the conversion slices that follow
(`.1` … `.N`) know which of the ~1,600 names should become a settings row,
which already are one, and which are a secret, a loop variable, a test seam
or box layout that a settings row could never move.

**How an operator reaches it:** `bin/config-inventory.sh [--root <path>]
[--out <dir>]` — no flags needed for the common case, defaults to scanning
this repo and writing `docs/config-inventory/`. No network call, no git
write; it is safe to run against a live checkout at any time and re-run
whenever `bin/`, `fly/`, `cron/`, `worker/jobs/src` or `console-ui/src`
change. There is no cron lane and no console screen — this is a build-time
tool, not a fleet mechanism.

**Output, all regenerated every run, none committed.** The renders are
generated and git-ignored (BH-5518): to read them, run `bin/config-inventory.sh`,
then open `docs/config-inventory/index.html`. `bin/config-inventory.sh --check`
is the freshness proof: it renders the tree twice into temp dirs and fails
(rc 1) when the two differ, when any path under `docs/config-inventory/` is
tracked, or when `deployment.md` records an un-allowlisted literal; rc 2 means
it could not run. CI runs it in the "derived docs" step.
- `docs/config-inventory/inventory.json` — the whole answer: every
  variable's class, the rule that fired, every read site, the default(s)
  seen (conflicting ones flagged), whether it overlaps #1510 (model/runner
  routing — out of scope here), whether its default is a computed shell
  expression rather than a literal value, the endpoint literals found, the
  duplicate-meaning groups, and the proposed conversion slices grouped by
  subsystem.
- `docs/config-inventory/index.html` — a self-contained, sortable-table
  summary of the same data for a human to read without `jq`.

**Classification, in order** (bin/config-inventory.py's own docstring is the
source of truth; this is the summary):
1. `ALREADY_REGISTERED` — a `.knobs[].env` in some `catalog/lanes.d/*.json`,
   recomputed by this generator every run, never read from a snapshot.
2. `SECRET` — a `TOKEN`/`SECRET`/`PASSWORD`/`CREDENTIAL(S)`/`KEY`/`PAT`
   suffix, the same shape `tests/lanes-registry-test.sh` section 13 already
   refuses from the registry, widened by the `PAT` suffix #1511's own ticket
   body names.
3. `BOX_LAYOUT` — a known repo-root-relative name, or a default that is
   itself a filesystem path under `/root`, `/tmp`, `./` or `$HARNESS`.
4. `TEST_HOOK` — assigned only inside `tests/`, never by the production code
   that reads it: a seam a test pokes, not an operator knob. Three kinds of
   knob evidence beat a test assignment: a production self-init, any
   non-empty production default, and an IN-CODE FALLBACK — a read whose
   literal default is empty (`${X:-}`) because the real default is the next
   argument to a knob helper (`br_knob_num X "${X:-}" 12`, `num_or "${X:-}"
   14`), the clamp under it (`case "${X:-}" in ''|*[!0-9]*) X=45 ;;`) or the
   message beside it (`X='${X:-}' is not a number — treating as 600`). Those
   three shapes and nothing wider: a plain equality compare
   (`[ "${X:-}" = 1 ]`) is how a genuine seam is read too, so the handful of
   real levers read that way (`GROK_BILLING`) are listed by hand in
   `MANUAL_KNOB_EVIDENCE` instead. A name the reading file itself assigns is
   never a test hook either, whatever a test does with it — that is rule 5.
   Nor is a name that one stage module of `bin/run-build.sh` (`bin/lib/rb/`)
   or `bin/run-triage.sh` (`bin/lib/rt/`) assigns and another reads: the
   driver sources them into one shell, so it is `PLUMBING`
   (`stage-module-assigned`, BH-5518). This applies only in place of
   `TEST_HOOK`. It does not widen rule 5, because that moved 11 `CONFIG` names.
5. `PLUMBING` — a bash/CI builtin (`BASHPID`, `GITHUB_*`, …); a name ported
   from `tests/lanes-registry-test.sh`'s own reviewed PLUMBING allowlist; or
   a name the SAME production file also assigns (a local or loop variable).
   The `NAME="${NAME:-default}"` self-init idiom — how most real knobs in
   this codebase declare themselves — is explicitly excluded from this rule;
   an early version of the generator misread it as evidence of "local, not a
   knob" and mass-misclassified genuine config as plumbing (caught by
   `tests/config-inventory.bh-1511-test.sh`'s fixture for exactly this
   idiom before this entry's PR landed). The exclusion is COUNTED, not
   blanket: `X=$(cmd); X="${X:-0}"` on one line is one real assignment plus
   one self-init, so X is plumbing — reading it as "X has a self-init, drop
   every assignment of X on that line" filed 15 computed locals (`BEFORE`,
   `VCUR`, `DEFER`, `LN0`, …) as settings-row candidates.
6. Everything else with a command/host/path/identity-shaped suffix (the same
   `HAZ` regex `tests/lanes-registry-test.sh` section 17 uses to gate
   settings-row write access) gets a suffix- or name-level manual rule this
   generator's author set by reading the surrounding code — tagged
   `manual:<reason>` so it is honest about being a rule, not a per-instance
   read of every name. A hazard-shaped name no rule resolves is `UNDECIDED`
   (zero of them on `main` as of this entry — every hazard shape found had a
   resolvable rule).
7. What's left — no registry hit, no secret/box/test/plumbing shape — is
   `CONFIG`: the settings-row candidate #1511 exists to find.

**Deferred to #1510, not #1511:** any `*_MODEL` name, any default shaped
like a model VERSION (`claude-opus-*`, `claude-sonnet-*`, `gpt-6`, `grok-4`,
`kimi-k2`, `deepseek-v4`, …), and any `RUNNER_*` runner-selection lever stay
classified `CONFIG` (they are real settings) but are flagged
`deferred_to_1510` and excluded from the proposed conversion slices —
#1510's `model_routes` table is meant to own them, not a plain settings row
minted here. Three things that LOOK like the above and are not: a CI runner
(`CI_RUNNERS`, `CI_RUNNERS_LABEL`, `BATCH_CI_RUNNERS`, `SUITE_RUNNER_LABEL` —
a GitHub Actions machine label, not a model runner), a shell/CI builtin
(`RUNNER_TEMP`), and a default that merely STARTS with a vendor word
(`claude-auth-down.txt` is a state file, which is why the value check wants a
version shape, not `claude-<anything>`). All of those stay in #1511's scope.

**Endpoint literals:** `CONFIG` when the line drives a network call —
`curl`/`fetch`/`axios`/`requests`/`urllib`/`Request(`/`base_url=`/
`os.environ.get(`/`process.env.X ||`, bash's own `api_get "https://…"`, any
assignment `name = <url>`, or a URL that is the DEFAULT of a variable read
(`X="${X:-https://…}"`, a call target the variable side already carries).
`DOC` otherwise: a comment, a literal holding a regex metacharacter, a log
line — or an interpolated `github.com/$slug/pull/$num`-style link to a
pull/issue/run/commit PAGE, which is a link a human clicks, not an address
this code calls. A `github.com/$slug.git` REMOTE has no such path and stays a
call target.

**How the suite proves it:** `tests/config-inventory.bh-1511-test.sh` builds
a small fixture tree covering all six classes plus the two flags, runs the
real generator against it, and asserts each fixture variable landed in the
class its own comment says it should — red before this entry's fix, green
after. It also asserts the endpoint CONFIG/DOC split, that a conflicting
default is caught and filtered into the "actionable" list only when the
name is CONFIG or ALREADY_REGISTERED-class, that the generator writes
nothing outside `--out`, and — the freshness half — that two renders of
the tree right now agree on a line-free projection, and that
`docs/config-inventory/inventory.json` is not tracked (BH-5518). Nothing is
committed, so there is no stored copy to go stale the way
`docs/verification-map/README.md` used to before BH-1175.

`tests/config-inventory.bh-1530-test.sh` is the second suite, and it pins the
five rules above that a round-2 review of the original PR found still wrong
(the counted self-init, the CI-runner/model-version deferral, locals a test
also sets, in-code-fallback knobs, URL-default and `api_get` call targets)
plus the one-file-one-slice invariant — on fixture trees AND as HARD
assertions against a fresh render of this tree's `inventory.json`, so a later
`bin/` edit that re-breaks one of them is caught rather than quietly re-filed.

**Slicing: one file, one slice.** `proposed_slices` is cut so that two
INDEPENDENT slices never touch the same file — vars are partitioned into
file-connected components (share a read file, share a slice) before subsystem
grouping, because a slice's `files` is the union of all files reading its
vars, and grouping by subsystem first put 38 files in more than one slice
(`bin/agent-call.sh` in 9). Nine conversion PRs cutting the same file in
parallel is nine conflicts on a hunk no ticket is about. A component too big
for the ≤40-knob / ≤12-file caps cannot be both file-disjoint and reviewable,
so it is cut into a SERIAL chain instead: each link carries `serial_group`,
`order` ("2 of 4") and `blocked_by`, and the links are cut one PR after
another, never in parallel. Nothing is dropped to make a slice fit — a single
var reading more files than the cap allows ships flagged `over_cap_files`.

**Not a class (R2-N5), and no slice should mint a row for one.** Two families
look like settings and are not. CALLER-SUPPLIED CONTEXT: `COST_KEY`,
`COST_JOB`, `COST_PROJECT`, `COST_STAGE`, `COST_ACCT_NAME`, `BUILD_ATTEMPT`,
`COST_RUN_ID` — what the caller hands the script for this invocation.
OUTPUT/STATUS: `JOBS_BODY`, `JOBS_TRANSCRIPT_TRUNCATED`, `JOB_REFUSED`,
`LLM_GATE_REASON`, `SRC` — what the code computes and passes back out. They
land in `CONFIG` or `TEST_HOOK` like anything else and a slice author drops
them on sight. No class of their own is minted: that would change the
`by_class` schema every consumer reads, so if one is wanted it is its own
slice.

**Not covered by this slice:** no lane behaviour changes, no knob is
registered, no default is removed from any script. That is `.1` … `.N`, one
PR per proposed slice in `inventory.json`'s `proposed_slices` array, plus a
dedicated endpoints slice for the `service_endpoints` conversion. This entry
proves the map is accurate, not that anything downstream of it has moved
yet.

## Deployment assumptions (BH-4080)

The variable pass above only sees a value that is already behind a name. The
deployment pass is for the literal with no name around it: our GitHub org and
the harness repo, Orgo box hostnames and the hub's fleet name, the operator's
login and commit email, the bot's commit identity, the billing accounts, the
workers.dev subdomain, tailnet addresses and MagicDNS names, the Orgo API host.
The families are data, `catalog/deployment-literals.tsv` (one regex per family,
most specific first; a match is blanked before the next family runs, so
`operator_home@example.com` is one billing-account hit, not also an operator-login hit).

**Where the values live now.** One home per surface, each the only place the
literal is written:

- shell: `bin/lib/deployment.sh`, one `: "${X:=default}"` per knob, registered
  in `catalog/lanes.d/_lib.deployment.json`, every knob `settable: false`
  (`HARNESS_REPO`, `HARNESS_GH_OWNER`, `HARNESS_OPERATOR_LOGIN`,
  `HARNESS_GIT_NAME`, `HARNESS_GIT_EMAIL`, `HARNESS_MERGE_GIT_NAME`,
  `HARNESS_BOT_GIT_NAME`, `HARNESS_BOT_GIT_EMAIL`, `HARNESS_WORKERS_SUBDOMAIN`,
  `HARNESS_BOX_PREFIX`, `HARNESS_HUB_BOX`). An operator sets them in
  `env/global.env` (`env-templates/lanes/377-deployment-defaults.env.example`);
  the defaults are this fleet's values, so nothing moves here. A consumer
  sources `"${HARNESS_DEPLOYMENT_FILE-<beside itself>/deployment.sh}"` and
  fails when it is missing; the variable is unset on a box, and
  `tests/lib/scratch.sh` points it at the checkout's copy for scratch trees.
- console: `console-ui/src/lib/deployment.js` (`FLEET_LOGIN`,
  `PRODUCT_COCKPIT_URL`). A static build has no box env; console-editable is
  #3979 wave 8.
- jobs worker: `worker/jobs/src/lib/deployment-defaults.js`
  (`ANCHOR_DEFAULT_ACCOUNT_MAP`, overridden by `env.COST_ANCHOR_ACCOUNT_MAP`).
- project repo slugs: fleet.conf column 2 through `bin/fleet-conf.sh`. The
  lander, deploy train, merge queue, migration-PR check, unblocked-children,
  dep-verify and triage gate no longer carry a slug table; a project with no
  row gets no guessed slug.

**The lint.** `bin/deployment-lint.sh [--root <path>] [--families <file>]
[--allowlist <file>]` scans `bin/ fly/ cron/ worker/jobs/src/ console-ui/src/
locks-worker/src/` (`.sh .py .mjs .js .cron`; `.wrangler/`, `node_modules/` and
`__pycache__/` skipped). A comment line is skipped by language (`#` for shell,
Python and crontab; `//`, `/*`, ` * ` for JS); a trailing comment and a Python
docstring are scanned. It prints `path:line<TAB>family<TAB>text` per hit and
`allowlist:<n>: …` per allowlist problem, writes nothing, and exits 0 clean, 1
hits or problems, 2 could not run (no families file, an empty one, an
unreadable named allowlist). The exceptions are
`tests/no-hardcoded-deployment-allowlist.txt`, `<path> <family>[,family]
<reason>`: an entry with no reason, for a missing file, for an unknown family,
or for a family the file no longer carries, fails.

**The report.** Every run of `bin/config-inventory.sh` also writes
`deployment.json` and `deployment.md` next to `inventory.json`:
per family the knob and its registry default, the files that read it, the
allowlisted exceptions with their reasons, and an "already configuration"
section (model routes, Telegram/Slack, tailnet and the box column, account
ids, hub paths). Like the inventory, both are git-ignored (BH-5518).
`tests/no-hardcoded-deployment.bh-4080-test.sh` R1 fails when the report lacks
a family section or records an un-allowlisted literal, when
`bin/config-inventory.sh --check` is not green, or when any path under
`docs/config-inventory/` is tracked.

**Not covered.** Hub paths (`/root/harness`, `/root/repos`) are already
`${HARNESS:-…}` reads with an override and are not linted. Lowercase Fly app
names (`bh-testhost-<org>`) are `${VAR:-}` knob defaults the variable pass
already classifies. A literal assembled at runtime, an extensionless script and
any file outside the scanned dirs are not seen.
