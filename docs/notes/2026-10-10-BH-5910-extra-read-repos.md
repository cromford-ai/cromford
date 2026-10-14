# Pool builds can read a second repo; a plan that cannot stops at PLAN (BH-5910)

Doc: OPERATOR-SETUP, RUN-BUILD-GRAPH

## What happened

A pool machine's GitHub token sees one repo: the project's own. A plan that
copied code from a second repo ran a full execute stage, got `Repository not
found` on the clone, and ended with an empty diff.

## What changed

1. A new per-project knob, `EXTRA_READ_REPOS` (settings row
   `lane.fly-pool.<project>.extra_read_repos`, `catalog/lanes.d/fly-pool.json`).
   It is a list of `owner/repo`, comma or space separated, at most 10. The
   default is empty, which is the old behavior.
2. `bin/gh-token.sh --extra-read <csv> <owner/repo>` mints a SECOND token. Its
   body lists the project repo plus the extra repos, with
   `permissions:{contents:"read",metadata:"read"}`. The project token
   (`gh-token.sh <owner/repo>`) does not change and never reads the list.
   - Two tokens, not one: GitHub applies a token's permissions to every repo in
     it. One token with both repos would give the extra repo the App's write
     permissions, or take write away from the project repo.
   - Each extra repo is checked first with `GET /repos/<repo>/installation` on
     the App JWT. A repo on another owner, on another installation, or with a
     404 is logged as `EXTRA_READ_REPO_MISSING <repo>` on stderr and in
     `logs/gh-rate.log`, and is dropped. A failed check adds `(unverified)`.
     An entry that is not `owner/repo` adds `(not owner/repo)`.
   - Unarmed, killed, nothing left to mint, or a failed mint: rc 1 and no
     output. This mode never falls back to the PAT or to the hub App.
   - The cache key is `<owner/repo>#xread-<8 hex of the list>`, so a changed
     list never reuses an old token.
3. `bin/fly-pool.sh` (spawn swap block) asks for that token when the knob is set
   and the project token came from an App mint. It writes `GH_EXTRA_READ_TOKEN`
   and `GH_EXTRA_READ_REPOS` into the machine's `global.env` and pushes the token
   to `/run/harness-env/gh-token-read`. Each missing repo writes one ALERTS line
   per project per repo per UTC day (`flags/alerted-extra-read-missing-*`,
   pruned after 48 h). With no read token the machine still ships with the
   project token.
   - `GH_EXTRA_READ_REPOS` is never the raw settings row. The builder loads
     `global.env` with `. ` as root, so the swap writes only the `owner/repo`
     words, without the project repo and the missing repos, deduped, sorted,
     capped at 10 and joined by commas. A space-separated row ships as a comma
     list. A word with shell text (`$(...)`, a backtick, a newline) is dropped.
4. `fly/gh-credential.sh` answers the read token only for a request whose path
   is one of `GH_EXTRA_READ_REPOS`. `fly/builder-runner.sh` sets
   `credential.https://github.com.useHttpPath true` when the read file exists,
   so git sends the path. A push to the project repo still gets the project
   token.
5. The plan prompt asks the planner for one line per repo it will read:
   `CROSS-REPO-READ: <owner>/<repo>`. The new gate
   (`bin/lib/rb/cross-repo-read.sh`, block `# >>> cross-repo-read gate
   (BH-5910)` in `bin/lib/rb/plan.sh`) probes each declared repo with
   `GET /repos/<repo>` on each token the build holds. A 404 on every token ends
   the build `PLAN_BLOCKED cross-repo-read <repo>`, with a `BLOCKED:` first line
   in `plan.md` and one ALERTS line. Any other probe answer (401, 403, 429, 5xx,
   timeout, no token) is one `pipeline.log` line and does not block.
   - The gate runs below the PLAN checkpoint, so a pre-plan HIT and a resumed
     build meet it too. `bin/run-preplan.sh` puts the same sentence in the
     pre-plan prompt.

## Not in this change

- The read token is not rotated. It is minted with the same
  `POOL_GH_TOKEN_MIN_LIFE` as the project token (55 minutes or more at spawn).
  A git read of the extra repo after it expires fails the same way as before.
- The probe passes each token to curl as a `-H` argument, so the token is in
  the builder's process list for up to 10 s. `bin/gh-token.sh` does the same.
- `gh` CLI calls still use `GH_TOKEN` (the project token). Only git reads use
  the read token.

## Operator steps to turn it on for a project

1. Install the builders GitHub App on each extra repo. It must be on the same
   owner as the project repo.
2. Set the settings row `lane.fly-pool.<project>.extra_read_repos` to the list,
   for example `example-org/OtherRepo`.
3. Watch `logs/gh-rate.log` and ALERTS for `EXTRA_READ_REPO_MISSING` on the next
   spawn of that project.
