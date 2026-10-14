# BH-1193: bin/run-tests-in-docker.sh can run against a remote docker host

**What changed.** The suite runner no longer assumes the daemon is on this
machine. `bin/lib/docker-host.sh` resolves the endpoint in one place and
`bin/run-tests-in-docker.sh` exports it before its first `docker` call, so
`docker info`, `docker image inspect`, `docker build` and the run all go to the
same daemon and the image is built where the suites will run.

**Why a knob was not enough on its own.** Exporting `DOCKER_HOST` at the old
script did something worse than nothing. The run was `docker run -v
"$REPO:/repo:ro"`, and a bind mount resolves on the DAEMON's host: against a
remote endpoint that path does not exist there, docker creates an empty `/repo`
without complaining, and `suite_runner_main` finds no suites. So on a remote
endpoint the runner now stages the checkout with `rsync -rlptD --delete`
(excluding `.git`, `node_modules`, `.claude`, `.codegraph` — the
`bin/remote-gate.sh` list, and `docker cp` honours no `.dockerignore`) and does
`create` -> `cp` -> `start -a`, with `docker rm -f` and the staging dir removed
from an `EXIT`/`INT`/`TERM` trap. The exit status is `start -a`'s and nothing
else's, so a container that was created and never started cannot report a green
run. `start` takes `-a` and never `-i`: the container keeps the empty stdin
BH-514 bought.

**A non-zero status is only a suite count once docker says the container ran.**
`docker start` answers 1 for a docker-level failure — the daemon died between
the `cp` and the start, the host refused the container — and 1 is also an
ordinary "one suite failed", so the two are indistinguishable from the status
alone. The local path never had the ambiguity: `docker run` answers 125 there,
outside the plausible count. So on a non-zero status the runner asks
`docker inspect --format '{{.State.Status}}'`: `exited` means the suites ran and
the status is the run's; anything else is `exit 2`, "the run could not happen".

**The image build sends no context.** The inline Dockerfile has no `COPY` and no
`ADD`, so the `$REPO` context it used to pass was never read — locally that cost
nothing, but against `ssh://root@<host>` the client tarred and shipped the whole
checkout (47 MB here) over the link before the build could start. The context is
`-` now: the Dockerfile on stdin, zero bytes of context.

**The local path did not move.** With no endpoint configured the `docker run`
argv is byte-identical to what it was, including the bind mount. One line was
added to both paths: `run-in-docker: running on <endpoint>` or `running on the
local docker daemon`, printed from the resolved value rather than from a guess,
so a green run always says where it ran.

**Precedence, and what "not configured" means.** First a non-blank
`DOCKER_HOST` already in the environment, then `DOCKER_HOST` set by `<env
dir>/global.env` (sourced in a subshell — only that one variable comes out, and
a `#DOCKER_HOST=` line is therefore a comment and not a setting), then nothing,
which is the local daemon. Blank, whitespace-only, `unix://…` and `fd://…` are
local; `ssh://`, `tcp://` and `npipe://` are remote. A missing `global.env` or a
missing env dir is not configured, not broken. "Not configured" is also carried
into docker's own environment: an empty or whitespace-only `DOCKER_HOST` is
UNSET before the first docker call, not merely skipped over, or every call would
carry a value the run line has just called local and the client would fail to
parse it under a message pointing at Docker Desktop.

**A configured endpoint that does not answer is `exit 2`.** No fall back to the
local daemon, no warning-and-continue: falling back would put ten containers
straight back on the machine the endpoint exists to take them off, which is the
condition this ticket is about. Same for a missing `rsync`, a failed stage, a
failed `create` and a failed `cp` — all `exit 2`, all before anything runs.

**CI may not skip the remote sections.** The suite needs a real `rsync` to stage
a real tree, so a machine without one has nothing to drive. A dev laptop still
skips; CI does not. `fly/Dockerfile` installs `rsync` (the `bh-ci` image was the
one machine in the fleet without it), the tests step guard-installs it the way
it guard-installs `age` and `zstd`, and it exports `RSYNC_REQUIRED=1` so a
runner that still cannot find one is red instead of one skip line and an exit 0.
That is the BH-1128 shape — three harness-sync suites printing "rsync missing —
skipping" and passing — and this ticket's whole evidence sat behind it.

**Standing a host up (operator steps — this build ran none of them).** On a box
with spare RAM: install docker, allow ssh as a user that can reach the docker
socket, then on the Mac `DOCKER_HOST=ssh://root@<host>` in `env/global.env`
(the template is `env-templates/lanes/370-remote-docker-host.env.example`).
`bin/run-tests-in-docker.sh tests/verification-map-build-test.sh` builds the
image on that host on the first run and prints the endpoint it used. No host is
named here on purpose: `bh-testhost-example-org` is the obvious candidate
(already `performance-16x`, already owned by `bin/testhost-tick.sh`), but
nothing in this repo says docker is installed on it and this build did not check.

**The tag is `:trixie.2`, and the ticket says `:trixie`.** The ticket predates
BH-1128, which moved the suffix precisely because `:trixie` carries no `rsync`
and a machine holding that tag silently skips three harness-sync suites. Going
back to it would turn `tests/run-tests-in-docker.bh-1128-test.sh` red and
re-ship that bug, so the `^IMAGE=` line was not touched. Read the ticket as "the
test image", not as that literal tag.

**Cost.** One machine for as long as a drain runs; destroy it after. Nothing in
this change starts, stops or bills a machine — it calls no metered API and never
invokes flyctl.

**What this build verified, and what it did not.** Verified, in this session,
with a stub `docker` recording every verb's argv: the resolver's precedence and
its nine local/remote classifications, the local path unchanged, the remote
path's `create`/`cp`/`start` order with no `-v`, a named suite forwarded, the
empty container stdin, the `rm` and the staging removal on a failing run, an
unreachable endpoint exiting 2 with nothing run locally, a whitespace-only
endpoint reaching docker as nothing at all, a container that never left
`created` exiting 2 while one genuinely failing suite still exits 1, the image
built on the resolved daemon with the same tag and no context, and two
concurrent runs sharing no staging directory
(`tests/run-tests-in-docker.bh-1193-test.sh`, 79 assertions). NOT
verified: any real remote host — no daemon was contacted, no image was built
anywhere, and the ticket's "ten concurrent suites without a SIGKILL" is an
operator check on a real host that this build could not run.

**Not changed.** The agent limiter the ticket mentions ("can then go to 10 to
12") belongs to the Mac drain's own launcher, not to this repo; the in-repo caps
(`BUILD_SLOTS`, `flags/wip-limit-<project>`) are box build slots, a different
thing, and raising anything on the strength of a host nobody has stood up yet
would be the wrong order. `bin/remote-gate.sh` and `bin/testhost-tick.sh` are
untouched: different transport, different knobs, no shared state, and both can
run while this one does.

Doc: REMOTE-GATE
