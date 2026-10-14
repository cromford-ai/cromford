# The local test image runs gawk as awk; the tag moves to trixie.5 (BH-5583)

Doc: FLAKY-TESTS

## What changed

- The image `bin/run-tests-in-docker.sh` builds installs `gawk`. The same
  `RUN` sets the awk alternative with
  `update-alternatives --set awk /usr/bin/gawk` and then checks that
  `awk --version` starts with `GNU Awk`.
- If either step fails, `docker build` fails. The runner then prints
  `run-in-docker: image build failed.` and exits 2. No image is tagged and no
  suite runs.
- The default tag is `:trixie.5`. A machine that holds `:trixie.4` builds the
  new image on its next run, because `docker image inspect` finds no
  `:trixie.5`. The header lists `:trixie.4` as the mawk-as-awk tag.
- mawk stays installed. Suites that call `mawk` by name still find it.

## Why

CI's shards run gawk. Debian trixie's default `awk` is mawk. The two parse an
`awk -v` value differently: gawk turns `\(` into `(`, and mawk keeps the
backslash. `tests/prompt-conflict-discipline.bh-5269-test.sh` passed in the
image and failed 7 cases in merge batch #5686.

## Test

`tests/run-tests-in-docker-image.bh-5583-test.sh` reads the runner's text. It
needs no docker. It checks the package list, the alternative and the GNU check,
the default tag, the header and the package comment.

## Not done here

The image build was not run when this note was written: the build box had no
docker. Run these where docker exists:

1. `bin/run-tests-in-docker.sh tests/run-tests-in-docker-image.bh-5583-test.sh`
2. `docker run --rm cromford-tests:trixie.5 sh -c 'readlink -f "$(command -v awk)"; awk --version | head -n1'`
   must print `/usr/bin/gawk` and `GNU Awk 5.x`.
3. `bin/run-tests-in-docker.sh tests/prompt-conflict-discipline.bh-5269-test.sh`
