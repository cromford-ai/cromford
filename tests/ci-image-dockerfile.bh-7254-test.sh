#!/bin/bash
# tests/ci-image-dockerfile.bh-7254-test.sh — the shared CI base image
# (ci-images/base/) pins every version it installs, carries every tool the
# harness suites call, and its build script and workflow tag and push it by the
# rules docs/CI-IMAGES.md gives.
#
# WHAT THIS PINS.
#   D  check_dockerfile <dockerfile> <runner-script> prints one finding per line;
#      the real ci-images/base/Dockerfile gives 0 findings:
#      D1 FROM is the base of bin/run-tests-in-docker.sh's image (a digest, if
#         present, is a full sha256);
#      D2 every ARG *_VERSION has an exact x.y.z default, every ARG *_SHA256 a
#         64-hex default; no `latest` token; no pipe into sh/bash;
#      D3 playwright@${PLAYWRIGHT_VERSION}, `playwright install --with-deps
#         chromium`, PLAYWRIGHT_BROWSERS_PATH; node/shellcheck/gh/yq install
#         through their ARG and check `--version` against it; gh and yq check
#         the vendor's checksum list, shellcheck its literal sha256;
#      D4 the shellcheck pin and sha256 equal bin/ci-shellcheck.sh's;
#      D5 the node major equals CI's (bin/lib/test-image-node.sh ci_node_major);
#      D6 every apt package of bin/run-tests-in-docker.sh, plus sqlite3, is in
#         the apt list; awk is set to gawk and checked to be GNU Awk;
#      D7 the ticket's tool list, and /root/.cache/prisma;
#      D8 scratch mutations of the Dockerfile each give their finding.
#   B  ci-images/base/build.sh with a fake docker on PATH:
#      B1 tag <image>:<sha12>, --platform linux/amd64, no :latest, a context of
#         exactly Dockerfile + node-install.sh (byte-equal to the real files);
#      B2 --latest adds <image>:latest;
#      B3 --push pushes each tag and prints digest=/size=; the workflow's own
#         summary extraction line reads them back unchanged;
#      B4 short, non-hex and missing arguments exit 2 with 0 docker calls;
#      B5 a failed build exits 1, pushes nothing, removes the context;
#      B6 a good build removes the context.
#   W  .github/workflows/ci-image.yml (SKIP when absent, as in the public copy):
#      W1 triggers and path filters; W2 runner variable, permissions, IMAGE;
#      W3 --latest only on a non-PR event on main; W4 fork PRs neither log in
#      nor push, PRs tag the head sha; W5 the ticket's smoke command;
#      W6 every step with a pipe runs under pipefail (shell: bash at step, job
#      or workflow level, or `set -o pipefail` in the run): GitHub runs a step
#      with no shell as `bash -e {0}`, so `build.sh | tee` would take tee's 0;
#      W7 each piped step, run as GitHub runs it with a build.sh and a docker
#      that exit 1, fails (a failed build or push must not be a green step).
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/ci-image-dockerfile.bh-7254-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
DF="$DIR/ci-images/base/Dockerfile"
BUILD="$DIR/ci-images/base/build.sh"
RUNNER="$DIR/bin/run-tests-in-docker.sh"
SC="$DIR/bin/ci-shellcheck.sh"
CI_WF="$DIR/.github/workflows/harness-ci.yml"
WF="$DIR/.github/workflows/ci-image.yml"
NODE_INST="$DIR/fly/testhost/node-install.sh"
PASS=0; FAIL=0; SKIP=0
ok()   { PASS=$((PASS+1)); }
bad()  { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
skip() { SKIP=$((SKIP+1)); echo "SKIP: $1"; }
finish() { echo "ci-image-dockerfile.bh-7254: $PASS passed, $FAIL failed, $SKIP skipped"; [ "$FAIL" -eq 0 ]; exit; }

# ── the checker ─────────────────────────────────────────────────────────────
# The apt list of a Dockerfile text: the words of the `apt-get install` RUN up
# to the first `&&` that is not the install itself.
apt_list() {
  awk '/apt-get install/ {on=1} on {print} on && /\\$/ == 0 {exit}' "$1" \
    | sed -e 's/.*apt-get install[^\\]*--no-install-recommends//' -e 's/&&.*//' -e 's/\\$//' \
    | tr ' ' '\n' | grep -E '^[a-z0-9][a-z0-9.+-]*$' | LC_ALL=C sort -u
}
arg_default() { sed -n "s/^ARG $2=\(.*\)$/\1/p" "$1" | head -n1; }

check_dockerfile() {
  local df="$1" runner="$2" from want_base base arg name val p major ci_major sc_pin sc_sha
  [ -r "$df" ] || { echo "dockerfile:missing"; return 0; }
  # D1
  from=$(sed -n 's/^FROM[[:space:]]\{1,\}\([^[:space:]]*\).*/\1/p' "$df" | head -n1)
  want_base=$(sed -n 's/^FROM[[:space:]]\{1,\}\([^[:space:]]*\).*/\1/p' "$runner" | head -n1)
  base="${from%%@*}"
  if [ -z "$from" ]; then echo "from:missing"
  elif [ -n "$want_base" ] && [ "$base" != "$want_base" ]; then echo "from:base-mismatch $base != $want_base"
  fi
  case "$from" in *@*) [[ "${from#*@}" =~ ^sha256:[0-9a-f]{64}$ ]] || echo "from:bad-digest" ;; esac
  # D2
  while IFS= read -r arg; do
    name="${arg%%=*}"; name="${name#ARG }"
    case "$arg" in *=*) val="${arg#*=}" ;; *) val="" ;; esac
    case "$name" in
      *_VERSION) [[ "$val" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || echo "arg:not-exact $name" ;;
      *_SHA256)  [[ "$val" =~ ^[0-9a-f]{64}$ ]] || echo "arg:bad-sha $name" ;;
    esac
  done < <(grep -E '^ARG [A-Z0-9_]+' "$df")
  grep -qiE '(^|[^a-z])latest([^a-z]|$)' "$df" && echo "latest-token"
  grep -qE '\|[[:space:]]*(sh|bash)([[:space:]]|$)' "$df" && echo "pipe-to-shell"
  # D3
  grep -qF 'playwright@${PLAYWRIGHT_VERSION}' "$df" || echo "playwright:not-pinned"
  grep -qE 'playwright install --with-deps chromium' "$df" || echo "playwright:no-chromium"
  grep -qE '^ENV PLAYWRIGHT_BROWSERS_PATH=/' "$df" || echo "playwright:no-browsers-path"
  grep -qE 'playwright --version.*PLAYWRIGHT_VERSION' "$df" || echo "verify:playwright"
  grep -qE 'node-install\.sh "\$NODE_VERSION"' "$df" || echo "install:node"
  grep -qE 'node --version.*NODE_VERSION' "$df" || echo "verify:node"
  grep -qF 'shellcheck/releases/download/v${SHELLCHECK_VERSION}/' "$df" || echo "install:shellcheck"
  grep -qE 'SHELLCHECK_SHA256\}?  .*sha256sum -c' "$df" || echo "checksum:shellcheck"
  grep -qE 'shellcheck --version.*SHELLCHECK_VERSION' "$df" || echo "verify:shellcheck"
  grep -qF 'cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_amd64.tar.gz' "$df" || echo "install:gh"
  grep -qF 'gh_${GH_VERSION}_checksums.txt' "$df" || echo "checksum:gh"
  grep -qE 'gh --version.*GH_VERSION' "$df" || echo "verify:gh"
  grep -qF 'mikefarah/yq/releases/download/v${YQ_VERSION}' "$df" || echo "install:yq"
  grep -qF 'checksums_hashes_order' "$df" || echo "checksum:yq"
  grep -qE 'yq --version.*YQ_VERSION' "$df" || echo "verify:yq"
  # D4
  if [ -r "$SC" ]; then
    sc_pin=$(sed -n 's/^SHELLCHECK_PIN=//p' "$SC"); sc_sha=$(sed -n 's/^SHELLCHECK_SHA256_x86_64=//p' "$SC")
    [ "$(arg_default "$df" SHELLCHECK_VERSION)" = "$sc_pin" ] || echo "shellcheck:pin-mismatch"
    [ "$(arg_default "$df" SHELLCHECK_SHA256)" = "$sc_sha" ] || echo "shellcheck:sha-mismatch"
  fi
  # D5
  if [ -r "$CI_WF" ]; then
    # shellcheck source=../bin/lib/test-image-node.sh
    ci_major=$(. "$DIR/bin/lib/test-image-node.sh" && ci_node_major "$CI_WF") || ci_major=""
    major=$(arg_default "$df" NODE_VERSION); major="${major%%.*}"
    [ -n "$ci_major" ] && [ "$major" = "$ci_major" ] || echo "node:major-mismatch"
  fi
  # D6
  local have; have=$(apt_list "$df")
  for p in $(apt_list "$runner") sqlite3; do
    grep -qx "$p" <<<"$have" || echo "apt:missing $p"
  done
  grep -qF 'update-alternatives --set awk /usr/bin/gawk' "$df" && grep -qF 'GNU Awk' "$df" || echo "awk:not-gawk"
  # D7
  for p in bash coreutils gawk jq sqlite3 util-linux git; do
    grep -qx "$p" <<<"$have" || echo "tool:missing $p"
  done
  grep -qE '^RUN mkdir -p /root/\.cache/prisma' "$df" || echo "prisma:no-cache-dir"
  return 0
}

# ── D: the real Dockerfile ──────────────────────────────────────────────────
if [ ! -f "$DF" ]; then
  bad "D: ci-images/base/Dockerfile does not exist"
else
  # The runner's apt list is the reference; an empty parse would make D6 vacuous.
  n=$(apt_list "$RUNNER" | grep -c .)
  [ "$n" -ge 10 ] && ok || bad "D6: parsed $n packages out of bin/run-tests-in-docker.sh's apt list, expected >= 10"
  [ -r "$SC" ] || skip "D4: bin/ci-shellcheck.sh absent"
  [ -r "$CI_WF" ] || skip "D5: .github/workflows/harness-ci.yml absent"
  out=$(check_dockerfile "$DF" "$RUNNER")
  [ -z "$out" ] && ok || bad "D1-D7: the real Dockerfile has findings:
$out"

  # D8: each mutation gives exactly its finding.
  mutate() { # <name> <expected finding> <sed expression>
    sed -e "$3" "$DF" > "$T/Dockerfile.$1"
    cmp -s "$DF" "$T/Dockerfile.$1" && { bad "D8 $1: the sed did not change the Dockerfile"; return; }
    got=$(check_dockerfile "$T/Dockerfile.$1" "$RUNNER")
    [ "$got" = "$2" ] && ok || bad "D8 $1: expected finding '$2', got '$got'"
  }
  mutate no-default  "arg:not-exact NODE_VERSION
node:major-mismatch"                                  's/^ARG NODE_VERSION=.*/ARG NODE_VERSION/'
  mutate pw-latest   "latest-token
playwright:not-pinned"                                's/playwright@${PLAYWRIGHT_VERSION}/playwright@latest/'
  mutate other-base  "from:base-mismatch debian:bookworm-slim != debian:trixie-slim" 's/^FROM debian:trixie-slim/FROM debian:bookworm-slim/'
  mutate bad-digest  "from:bad-digest"                's/^FROM debian:trixie-slim[^ ]*/FROM debian:trixie-slim@sha256:abc/'
  mutate no-rsync    "apt:missing rsync"              's/ rsync / /'
  mutate old-sc      "shellcheck:pin-mismatch"        's/^ARG SHELLCHECK_VERSION=.*/ARG SHELLCHECK_VERSION=0.10.0/'
  mutate pipe-sh     "pipe-to-shell"                  '$a RUN curl -fsSL https://example.invalid/i | sh'
  mutate no-prisma   "prisma:no-cache-dir"            's|^RUN mkdir -p /root/.cache/prisma.*|RUN true|'
  mutate gh-nosum    "checksum:gh"                    's/gh_${GH_VERSION}_checksums.txt/gh_sums/g'
  mutate yq-unver    "verify:yq"                      's/yq --version/yq version/'
  mutate node-major  "node:major-mismatch"            's/^ARG NODE_VERSION=[0-9]*\./ARG NODE_VERSION=99./'
  mutate mawk        "awk:not-gawk"                   's/update-alternatives --set awk \/usr\/bin\/gawk/true/'
fi

# ── B: build.sh with a fake docker ──────────────────────────────────────────
SHA40=0123456789abcdef0123456789abcdef01234567
SHA12=0123456789ab
FAKE_DIGEST=sha256:$(printf 'f%.0s' $(seq 64))
mkdir -p "$T/fakebin" "$T/tmp"
cat > "$T/fakebin/docker" <<'FAKE'
#!/bin/bash
# Fixture docker: logs argv, snapshots the build context, answers inspect.
printf '%s\n' "$*" >> "$FAKE_LOG"
case "$1" in
  build)
    ctx="${*: -1}"; echo "$ctx" > "$FAKE_STATE/ctx"
    rm -rf "$FAKE_STATE/ctxcopy"; cp -a "$ctx" "$FAKE_STATE/ctxcopy"
    exit "${FAKE_BUILD_RC:-0}" ;;
  push) exit 0 ;;
  image)
    case "$*" in
      *RepoDigests*) printf '%s\n' "other.example/x@sha256:0000" "$FAKE_IMAGE@$FAKE_DIGEST" ;;
      *Size*) echo 123456789 ;;
    esac ;;
esac
exit 0
FAKE
chmod 755 "$T/fakebin/docker"
export FAKE_LOG="$T/docker.log" FAKE_STATE="$T" FAKE_DIGEST FAKE_IMAGE=img
runb() { : > "$FAKE_LOG"; rm -f "$T/ctx"; rm -rf "$T/ctxcopy"
  PATH="$T/fakebin:$PATH" TMPDIR="$T/tmp" bash "$BUILD" "$@" > "$T/out" 2> "$T/err"; }
calls() { grep -c . "$FAKE_LOG"; }

if [ ! -f "$BUILD" ]; then
  bad "B: ci-images/base/build.sh does not exist"
else
  [ -x "$BUILD" ] && ok || bad "B: build.sh is not executable"
  # B1
  runb img "$SHA40"; rc=$?
  [ "$rc" = 0 ] && ok || bad "B1: rc $rc ($(cat "$T/err"))"
  b=$(grep '^build ' "$FAKE_LOG")
  case "$b" in *"-t img:$SHA12 "*) ok ;; *) bad "B1: no -t img:$SHA12 in: $b" ;; esac
  case "$b" in *"--platform linux/amd64"*) ok ;; *) bad "B1: no --platform linux/amd64 in: $b" ;; esac
  case "$b" in *"-t img:latest"*) bad "B1: :latest tagged without --latest" ;; *) ok ;; esac
  grep -q '^push ' "$FAKE_LOG" && bad "B1: pushed without --push" || ok
  [ "$(cd "$T/ctxcopy" 2>/dev/null && ls -A | tr '\n' ' ')" = "Dockerfile node-install.sh " ] && ok \
    || bad "B1: the context holds '$(ls -A "$T/ctxcopy" 2>/dev/null | tr '\n' ' ')', expected exactly Dockerfile node-install.sh"
  cmp -s "$T/ctxcopy/node-install.sh" "$NODE_INST" && cmp -s "$T/ctxcopy/Dockerfile" "$DF" && ok \
    || bad "B1: the context files are not byte-equal to the repo's"
  # B6
  ctx=$(cat "$T/ctx" 2>/dev/null)
  [ -n "$ctx" ] && [ ! -e "$ctx" ] && ok || bad "B6: the staged context '$ctx' is still there after a good build"
  # B2
  runb img "$SHA40" --latest
  case "$(grep '^build ' "$FAKE_LOG")" in *"-t img:latest"*) ok ;; *) bad "B2: --latest did not tag img:latest" ;; esac
  # 12 hex is taken as is
  runb img "$SHA12"; rc=$?
  [ "$rc" = 0 ] && grep -q -- "-t img:$SHA12 " "$FAKE_LOG" && ok || bad "B1: a 12-hex sha was not taken (rc $rc)"
  # B3
  runb img "$SHA40" --latest --push; rc=$?
  [ "$rc" = 0 ] && ok || bad "B3: rc $rc ($(cat "$T/err"))"
  [ "$(grep -c '^push ' "$FAKE_LOG")" = 2 ] && grep -qx "push img:$SHA12" "$FAKE_LOG" && grep -qx "push img:latest" "$FAKE_LOG" && ok \
    || bad "B3: expected one push per tag, got: $(grep '^push ' "$FAKE_LOG" | tr '\n' ';')"
  grep -qx "digest=img@$FAKE_DIGEST" "$T/out" && ok || bad "B3: no digest=img@$FAKE_DIGEST line in: $(cat "$T/out")"
  grep -qx "size=123456789" "$T/out" && ok || bad "B3: no size=123456789 line in: $(cat "$T/out")"
  # The round trip through the workflow's own summary extraction line.
  if [ -f "$WF" ]; then
    ex=$(grep -F "grep -E '^(image|digest|size)='" "$WF" | head -n1 | sed 's/^[[:space:]]*//')
    if [ -z "$ex" ]; then bad "B3: the workflow has no grep -E '^(image|digest|size)=' extraction line"
    else
      mkdir -p "$T/rt"; cp "$T/out" "$T/rt/build.out"
      got=$(RUNNER_TEMP="$T/rt" bash -c "$ex")
      grep -qx "digest=img@$FAKE_DIGEST" <<<"$got" && grep -qx "size=123456789" <<<"$got" && grep -qx "image=img:$SHA12" <<<"$got" && ok \
        || bad "B3: the workflow's extraction '$ex' gave: $got"
    fi
  else
    skip "B3 round trip: .github/workflows/ci-image.yml absent"
  fi
  # B4
  for a in "img abc" "img 0123456789a" "img zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz" "img" "" "img $SHA40 --bogus" "IMG $SHA40"; do
    # shellcheck disable=SC2086
    runb $a; rc=$?
    [ "$rc" = 2 ] && [ "$(calls)" = 0 ] && ok || bad "B4: '$a' gave rc $rc with $(calls) docker call(s), expected rc 2 and 0"
  done
  # B5
  FAKE_BUILD_RC=1 runb img "$SHA40" --latest --push; rc=$?
  [ "$rc" = 1 ] && ok || bad "B5: a failed build gave rc $rc, expected 1"
  grep -q '^push ' "$FAKE_LOG" && bad "B5: pushed after a failed build" || ok
  ctx=$(cat "$T/ctx" 2>/dev/null)
  [ -n "$ctx" ] && [ ! -e "$ctx" ] && ok || bad "B5: the staged context '$ctx' is still there after a failed build"
  [ -z "$(ls -A "$T/tmp")" ] && ok || bad "B5/B6: build.sh left files in TMPDIR: $(ls -A "$T/tmp" | tr '\n' ' ')"
fi

# ── W: the workflow ─────────────────────────────────────────────────────────
if [ ! -f "$WF" ]; then
  skip "W1-W5: .github/workflows/ci-image.yml absent"
  finish
fi
python3 -c 'import yaml' 2>/dev/null || { skip "W1-W5: python3 yaml missing"; finish; }
wf() { python3 - "$WF" "$1" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
on = d.get(True, d.get("on"))
job = d["jobs"]["build"]
steps = job["steps"]
q = sys.argv[2]
if q == "triggers": print(" ".join(sorted(on)))
elif q == "push-branches": print(" ".join(on["push"]["branches"]))
elif q.startswith("paths:"): print("\n".join(on[q[6:]]["paths"]))
elif q == "runs-on": print(job["runs-on"])
elif q == "perms": print(" ".join(f"{k}:{v}" for k, v in sorted(d["permissions"].items())))
elif q == "image": print(d["env"]["IMAGE"])
elif q == "piped":
    import base64, re
    dflt = ((job.get("defaults") or {}).get("run") or {}).get("shell") \
        or ((d.get("defaults") or {}).get("run") or {}).get("shell") or ""
    for s in steps:
        run = s.get("run") or ""
        # A shell pipe: `|` but not `||`, outside single-quoted text (a regex
        # alternation such as grep -E '^(a|b)' is not a pipe).
        if not re.search(r"(?<!\|)\|(?!\|)", re.sub(r"'[^']*'", "''", run)): continue
        sh = s.get("shell") or dflt or "default"
        print(s.get("name", "?").replace("\t", " ") + "\t" + sh + "\t"
              + base64.b64encode(run.encode()).decode())
elif q == "steps":
    for s in steps:
        print(repr(s.get("name", "")) + "\t" + repr(str(s.get("if", ""))) + "\t" + repr(s.get("run", "")) + "\t" + repr(s.get("env", {})))
PY
}
# W1
[ "$(wf triggers)" = "pull_request push workflow_dispatch" ] && ok || bad "W1: triggers are '$(wf triggers)'"
[ "$(wf push-branches)" = "main" ] && ok || bad "W1: push branches are '$(wf push-branches)'"
for ev in pull_request push; do
  for p in 'ci-images/base/**' fly/testhost/node-install.sh .github/workflows/ci-image.yml; do
    wf "paths:$ev" | grep -qxF "$p" && ok || bad "W1: $ev paths lack $p"
  done
done
# W2
case "$(wf runs-on)" in *vars.CI_RUNNER*) ok ;; *) bad "W2: runs-on '$(wf runs-on)' does not read vars.CI_RUNNER" ;; esac
[ "$(wf perms)" = "contents:read packages:write" ] && ok || bad "W2: permissions are '$(wf perms)'"
[ "$(wf image)" = "ghcr.io/example-org/ci-base" ] && ok || bad "W2: IMAGE is '$(wf image)'"
# W3: every step that passes --latest requires main and a non-PR event; some step does.
steps=$(wf steps)
lat=$(grep -F -- '--latest' <<<"$steps")
[ -n "$lat" ] && ok || bad "W3: no step passes --latest"
while IFS= read -r s; do
  [ -z "$s" ] && continue
  case "$s" in *"github.ref == 'refs/heads/main'"*"github.event_name != 'pull_request'"*) ok ;;
    *) bad "W3: a --latest step is not guarded by main + non-PR: $s" ;; esac
done <<<"$lat"
# W4: every step that logs in or pushes is guarded against fork PRs.
pushy=$(grep -E -- "--push|docker login" <<<"$steps")
[ -n "$pushy" ] && ok || bad "W4: no step logs in or pushes"
while IFS= read -r s; do
  [ -z "$s" ] && continue
  case "$s" in *"github.event.pull_request.head.repo.full_name == github.repository"*|*"github.event_name != 'pull_request'"*) ok ;;
    *) bad "W4: a login/push step has no fork guard: $s" ;; esac
done <<<"$pushy"
grep -qF 'github.event.pull_request.head.sha' "$WF" && ok || bad "W4: the PR tag sha is not github.event.pull_request.head.sha"
# W5
grep -F 'bash --version; node -v; npx playwright --version; jq --version' <<<"$steps" | grep -qF 'docker run --rm "$IMAGE:$SHA12"' && ok \
  || bad "W5: no smoke step runs the ticket's command against \$IMAGE:\$SHA12"
# W6 + W7: a piped step must fail when its first command fails.
piped=$(wf piped)
grep -q 'build.sh' < <(while IFS=$'\t' read -r _ _ b; do base64 -d <<<"$b"; done <<<"$piped") \
  && ok || bad "W6: no piped build.sh step found (the check would pass vacuously)"
mkdir -p "$T/w7/bin" "$T/w7/ci-images/base" "$T/w7/rt"
printf '#!/bin/bash\nexit 1\n' > "$T/w7/ci-images/base/build.sh"
printf '#!/bin/bash\nexit 1\n' > "$T/w7/bin/docker"
chmod 755 "$T/w7/ci-images/base/build.sh" "$T/w7/bin/docker"
while IFS=$'\t' read -r name sh b64; do
  [ -z "$name" ] && continue
  base64 -d <<<"$b64" > "$T/w7/step.sh"
  case "$sh" in
    bash) cmd=(bash --noprofile --norc -eo pipefail) ;;          # GitHub's `shell: bash`
    default) cmd=(bash -e) ;;                                    # GitHub's no-shell default
    *) bad "W6: step '$name' uses shell '$sh'; the check knows bash and the default only"; continue ;;
  esac
  if [ "$sh" = bash ] || grep -qE '^[[:space:]]*set -[a-z]*o pipefail|set -o pipefail' "$T/w7/step.sh"; then ok
  else bad "W6: step '$name' pipes without pipefail (no shell: bash, no set -o pipefail)"; fi
  ( cd "$T/w7" && PATH="$T/w7/bin:$PATH" RUNNER_TEMP="$T/w7/rt" GITHUB_STEP_SUMMARY="$T/w7/summary" IMAGE=img SHA=$SHA40 SHA12=$SHA12 \
      "${cmd[@]}" "$T/w7/step.sh" >/dev/null 2>&1 )
  rc=$?
  [ "$rc" -ne 0 ] && ok || bad "W7: step '$name' exits 0 when its first command exits 1 (rc=$rc under ${cmd[*]})"
done <<<"$piped"
finish
