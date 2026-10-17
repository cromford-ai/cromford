#!/bin/bash
# tests/ci-image-use.bh-7255-test.sh — harness-ci's lint, console-ui,
# worker-jobs and tests-shard jobs run in the prebuilt image when the switch
# is on, and exactly as before when it is off (BH-7255).
#
#   W  .github/workflows/harness-ci.yml, the production entry point:
#      W1 the four jobs run in `container:` needs.ci-image.outputs.ref, pulled
#         with the job token, and their permissions carry packages: read
#      W2 the four need ci-image; ci-image has no `if:` and reads CI_RUNNER
#      W3 ci-image runs `bin/ci-image.sh ensure` with the switch in env and
#         exports `ref`
#      W4 no step runs npm ci except a host-only one, no playwright install,
#         and every apt/npm -g/pip install sits behind a ci-tool-present guard
#      W5 every setup-node in the four jobs is host-only
#      W6 the two link steps are image-only, come before `npm test`, and their
#         run: lines, executed as written, link the baked tree
#   D  ci-images/cromford/Dockerfile:
#      D1 every tool a guard in the four jobs checks is baked, at that pin
#      D2 the node major is the workflow's node-version; ShellCheck and
#         gitleaks are the pins and digests of bin/ci-shellcheck.sh / the workflow
#      D3 no `latest`, and the FROM names a tag
#      D4 the COPY sources are exactly `bin/ci-image.sh inputs` minus the Dockerfile
#   T  bin/ci-image.sh tag / ref / stage: stable, moves on every input, ignores
#      other files, ref form, staged context is the inputs only
#   M  bin/ci-image.sh mode: the switch table and its negative list
#   E  bin/ci-image.sh ensure against a stub docker: host (no docker call),
#      present, missing+built+pushed, build fails, push fails, login fails,
#      bad switch, no docker
#   N  bin/ci-node-modules.sh: link, mismatch, no baked tree, a real dir, a
#      re-run, misuse; R1 the stamp written by the Dockerfile's own line
#
# Run from anywhere: bash tests/ci-image-use.bh-7255-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
WF="$DIR/.github/workflows/harness-ci.yml"
DF="$DIR/ci-images/cromford/Dockerfile"
CIMG="$DIR/bin/ci-image.sh"
CNM="$DIR/bin/ci-node-modules.sh"
BASH_BIN=$(command -v bash)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

for f in "$WF" "$DF" "$CIMG" "$CNM" "$DIR/bin/ci-shellcheck.sh"; do
  [ -r "$f" ] || { echo "FAIL: ci-image-use: missing $f"; exit 1; }
done
python3 -c 'import yaml' 2>/dev/null || { echo "FAIL: ci-image-use: python3 + PyYAML required"; exit 1; }

# ── W + D: the workflow and the Dockerfile, read together ───────────────────
PYOUT=$(python3 - "$WF" "$DF" "$DIR/bin/ci-shellcheck.sh" "$CIMG" <<'PY'
import re, subprocess, sys, yaml
wf_path, df_path, sc_path, cimg = sys.argv[1:5]
jobs = yaml.safe_load(open(wf_path))["jobs"]
df = open(df_path).read()
df_code = "\n".join(l for l in df.splitlines() if not l.lstrip().startswith("#"))
FOUR = ("lint", "console-ui", "worker-jobs", "tests-shard")
REF = "${{ needs.ci-image.outputs.ref }}"
HOST = "needs.ci-image.outputs.ref == ''"
IMAGE = "needs.ci-image.outputs.ref != ''"
def bad(m): print("BAD " + m)
def ok(): print("OK")
def steps(j): return (jobs.get(j) or {}).get("steps") or []
def needs(j):
    n = (jobs.get(j) or {}).get("needs") or []
    return n if isinstance(n, list) else [n]

# W1
for j in FOUR:
    b = jobs.get(j) or {}
    c = b.get("container") or {}
    ok() if isinstance(c, dict) and c.get("image") == REF else bad(f"W1: {j} must run in container.image {REF}: {c!r}")
    cr = (c.get("credentials") or {}) if isinstance(c, dict) else {}
    ok() if cr.get("password") == "${{ secrets.GITHUB_TOKEN }}" and cr.get("username") == "${{ github.actor }}" \
        else bad(f"W1: {j} must pull the image with the job token: {cr!r}")
    perms = b.get("permissions") or {}
    ok() if perms.get("packages") == "read" else bad(f"W1: {j} permissions need packages: read for the pull: {perms!r}")
# W2
ci = jobs.get("ci-image") or {}
ok() if ci else bad("W2: no ci-image job")
for j in FOUR:
    ok() if "ci-image" in needs(j) else bad(f"W2: {j} must need ci-image: {needs(j)!r}")
ok() if "if" not in ci else bad(f"W2: ci-image must have no if: (lint needs it on every event): {ci.get('if')!r}")
ok() if ci.get("runs-on") == "${{ fromJSON(vars.CI_RUNNER || '\"ubuntu-latest\"') }}" else bad(f"W2: ci-image must read CI_RUNNER: {ci.get('runs-on')!r}")
ok() if not needs("ci-image") else bad(f"W2: ci-image must need nothing: {needs('ci-image')!r}")
# W3
ens = [s for s in ci.get("steps") or [] if s.get("id") == "ensure"]
if len(ens) != 1:
    bad("W3: ci-image must have one step with id: ensure")
else:
    s = ens[0]; env = s.get("env") or {}
    ok() if str(s.get("run", "")).strip() == "bin/ci-image.sh ensure" else bad(f"W3: the ensure step must run bin/ci-image.sh ensure: {s.get('run')!r}")
    ok() if env.get("CI_IMAGE_VAR") == "${{ vars.CI_IMAGE }}" else bad(f"W3: CI_IMAGE_VAR must be vars.CI_IMAGE: {env.get('CI_IMAGE_VAR')!r}")
    ok() if env.get("CI_IMAGE_LABEL") == "${{ contains(github.event.pull_request.labels.*.name, 'ci-image') }}" \
        else bad(f"W3: CI_IMAGE_LABEL must be the exact ci-image label match: {env.get('CI_IMAGE_LABEL')!r}")
    ok() if env.get("GHCR_TOKEN") == "${{ secrets.GITHUB_TOKEN }}" else bad("W3: GHCR_TOKEN must be the job token")
ok() if (ci.get("outputs") or {}).get("ref") == "${{ steps.ensure.outputs.ref }}" else bad(f"W3: ci-image must export ref: {ci.get('outputs')!r}")
ok() if (ci.get("permissions") or {}).get("packages") == "write" else bad("W3: ci-image pushes a missing tag: packages: write")
for s in ci.get("steps") or []:
    if "actions/checkout" in str(s.get("uses", "")):
        ok() if (s.get("with") or {}).get("persist-credentials") is False else bad("W3: ci-image checkout must set persist-credentials: false")
# W4 + W5 + D1
INSTALL = re.compile(r"apt-get install|npm install -g|pip install")
GUARD = re.compile(r"ci-tool-present\.sh\s+(--python-module\s+)?([A-Za-z0-9_.-]+)(?:[ \t]+([0-9][0-9.]*))?")
guards = set(); installs = 0; ci_steps = 0
for j in FOUR:
    for s in steps(j):
        run = str(s.get("run", "")); cond = str(s.get("if", ""))
        code = "\n".join(l for l in run.splitlines() if not l.lstrip().startswith("#"))
        if "npm ci" in code:
            ci_steps += 1
            ok() if HOST in cond else bad(f"W4: {j} step {s.get('name')!r} runs npm ci in image mode too (if: {cond!r})")
        if "playwright install" in code:
            bad(f"W4: {j} step {s.get('name')!r} runs playwright install")
        found = GUARD.findall(code)
        for mod, tool, pin in found:
            guards.add(("module:" if mod else "") + tool + ("@" + pin if pin else ""))
        if INSTALL.search(code):
            installs += 1
            ok() if found else bad(f"W4: {j} step {s.get('name')!r} installs with no ci-tool-present guard")
        if "actions/setup-node" in str(s.get("uses", "")):
            ok() if HOST in cond else bad(f"W5: {j} setup-node must be host-only (if: {cond!r})")
ok() if ci_steps >= 2 else bad(f"W4: anti-vacuity: expected the two host-only npm ci steps, saw {ci_steps}")
ok() if installs >= 4 else bad(f"W4: anti-vacuity: expected the guarded install steps, saw {installs}")
apt = re.search(r"apt-get install[^;]*", df_code)
apt_pkgs = set(re.findall(r"[a-z0-9][a-z0-9.+-]*", apt.group(0).replace("apt-get install", ""))) if apt else set()
args = dict(re.findall(r"^ARG ([A-Z0-9_]+)=(\S+)$", df, re.M))
for g in sorted(guards):
    if g.startswith("module:"):
        m = g[len("module:"):]
        ok() if f"python3-{m}" in apt_pkgs else bad(f"D1: a guard checks python module {m}; the Dockerfile apt list has no python3-{m}")
    elif "@" in g:
        tool, pin = g.split("@")
        got = args.get(tool.upper() + "_VERSION")
        ok() if got == pin else bad(f"D1: a guard pins {tool} {pin}; the Dockerfile bakes {tool.upper()}_VERSION={got}")
    else:
        ok() if g in apt_pkgs else bad(f"D1: a guard checks {g}; the Dockerfile apt list has no {g}")
ok() if len(guards) >= 6 else bad(f"D1: anti-vacuity: expected the guards of the install steps, saw {sorted(guards)}")
# D2
majors = set(re.findall(r"node-version:\s*'(\d+)'", open(wf_path).read()))
nv = args.get("NODE_VERSION", "")
ok() if len(majors) == 1 and nv.split(".")[0] in majors and re.fullmatch(r"\d+\.\d+\.\d+", nv) \
    else bad(f"D2: Dockerfile NODE_VERSION={nv!r} must be an exact x.y.z of the workflow's node major {sorted(majors)}")
sc = open(sc_path).read()
pin = re.search(r"^SHELLCHECK_PIN=(\S+)", sc, re.M); sha = re.search(r"^SHELLCHECK_SHA256_x86_64=(\S+)", sc, re.M)
ok() if pin and args.get("SHELLCHECK_VERSION") == pin.group(1) else bad(f"D2: SHELLCHECK_VERSION must be bin/ci-shellcheck.sh's pin")
ok() if sha and args.get("SHELLCHECK_SHA256") == sha.group(1) else bad(f"D2: SHELLCHECK_SHA256 must be bin/ci-shellcheck.sh's x86_64 digest")
wsha = re.search(r"SHA=([0-9a-f]{64})", open(wf_path).read())
ok() if wsha and args.get("GITLEAKS_SHA256") == wsha.group(1) else bad("D2: GITLEAKS_SHA256 must be the workflow's gitleaks digest")
# D3
ok() if "latest" not in df_code else bad("D3: the Dockerfile names `latest`")
frm = re.findall(r"^FROM\s+(\S+)", df, re.M)
ok() if len(frm) == 1 and re.fullmatch(r"[a-z0-9./-]+:[A-Za-z0-9._-]+", frm[0]) and not frm[0].endswith(":latest") \
    else bad(f"D3: the FROM must name one image with a tag: {frm!r}")
# D4
inputs = subprocess.run(["bash", cimg, "inputs"], capture_output=True, text=True).stdout.split()
srcs = set()
for m in re.finditer(r"^COPY\s+(.+)$", df, re.M):
    parts = m.group(1).split()
    srcs.update(parts[:-1])
want = set(inputs) - {"ci-images/cromford/Dockerfile"}
ok() if srcs == want else bad(f"D4: COPY sources {sorted(srcs)} must equal the tag inputs {sorted(want)}")
ok() if "ci-images/cromford/Dockerfile" in inputs else bad("D4: the Dockerfile must be a tag input")
PY
)
while IFS= read -r l; do
  case "$l" in OK) ok ;; BAD\ *) bad "${l#BAD }" ;; esac
done <<<"$PYOUT"
[ -n "$PYOUT" ] || bad "W/D: the workflow reader printed nothing"

# W6: the link steps' run: lines, executed as written, in a fixture checkout.
LINKS=$(python3 - "$WF" <<'PY'
import sys, yaml
jobs = yaml.safe_load(open(sys.argv[1]))["jobs"]
for j in ("console-ui", "worker-jobs"):
    st = jobs[j]["steps"]
    names = [str(s.get("name", "")) for s in st]
    link = [i for i, s in enumerate(st) if "bin/ci-node-modules.sh" in str(s.get("run", ""))]
    test = [i for i, s in enumerate(st) if "npm test" in str(s.get("run", ""))]
    if len(link) != 1 or not test or link[0] > test[0]:
        print(f"BAD W6: {j} must have one ci-node-modules.sh step before npm test")
        continue
    s = st[link[0]]
    if "needs.ci-image.outputs.ref != ''" not in str(s.get("if", "")):
        print(f"BAD W6: {j} link step must be image-only: {s.get('if')!r}")
    if s.get("working-directory"):
        print(f"BAD W6: {j} link step runs from the checkout root")
    print("RUN " + str(s["run"]).strip())
PY
)
NRUN=0
while IFS= read -r l; do
  case "$l" in
    BAD\ *) bad "${l#BAD }" ;;
    RUN\ *)
      NRUN=$((NRUN+1)); cmd="${l#RUN }"
      W="$T/w6-$NRUN"; mkdir -p "$W/co/bin" "$W/baked"
      cp "$CNM" "$W/co/bin/"
      read -r _ pdir name <<<"$cmd"
      mkdir -p "$W/co/$pdir" "$W/baked/$name/node_modules"
      echo '{"lockfileVersion":3,"fixture":"'"$name"'"}' > "$W/co/$pdir/package-lock.json"
      (cd "$W/co/$pdir" && sha256sum package-lock.json | cut -d' ' -f1) > "$W/baked/$name/.lock-sha256"
      (cd "$W/co" && CI_NODE_BAKED_ROOT="$W/baked" "$BASH_BIN" -c "$cmd") >"$W/out" 2>&1; rc=$?
      if [ "$rc" = 0 ] && [ "$(readlink "$W/co/$pdir/node_modules")" = "$W/baked/$name/node_modules" ]; then ok
      else bad "W6: '$cmd' as written did not link $pdir/node_modules (rc=$rc): $(cat "$W/out")"; fi ;;
  esac
done <<<"$LINKS"
[ "$NRUN" = 2 ] && ok || bad "W6: expected two link steps to execute, ran $NRUN"

# ── T: tag, ref, stage ──────────────────────────────────────────────────────
FX="$T/fx"
bash "$CIMG" stage "$FX" && ok || bad "T0: stage into $FX failed"
STAGED=$(cd "$FX" && find . -type f | sed 's|^\./||' | LC_ALL=C sort)
[ "$STAGED" = "$(bash "$CIMG" inputs)" ] && ok || bad "T0: the staged context must be exactly the inputs: $STAGED"
[ "$(bash "$CIMG" inputs)" = "$(bash "$CIMG" inputs | LC_ALL=C sort)" ] && ok || bad "T0: inputs must be sorted"
tagof() { CI_IMAGE_ROOT="$1" bash "$CIMG" tag; }
T_REPO=$(tagof "$DIR"); T_FX=$(tagof "$FX")
[[ "$T_REPO" =~ ^[0-9a-f]{12}$ ]] && ok || bad "T1: tag '$T_REPO' is not 12 hex"
[ "$T_FX" = "$T_REPO" ] && [ "$(tagof "$FX")" = "$T_FX" ] && ok || bad "T1: the tag must be stable and equal on a staged copy ($T_REPO / $T_FX)"
while IFS= read -r f; do
  cp "$FX/$f" "$T/keep"; printf ' ' >> "$FX/$f"
  [ "$(tagof "$FX")" != "$T_FX" ] && ok || bad "T2: a 1-byte change to $f must move the tag"
  cp "$T/keep" "$FX/$f"
done < <(bash "$CIMG" inputs)
[ "$(tagof "$FX")" = "$T_FX" ] && ok || bad "T2: restoring every input must restore the tag"
mkdir -p "$FX/bin" "$FX/worker/jobs/src"; echo unrelated > "$FX/README.md"; echo x > "$FX/worker/jobs/src/index.js"; echo y > "$FX/bin/other.sh"
[ "$(tagof "$FX")" = "$T_FX" ] && ok || bad "T3: a file outside the inputs must not move the tag"
REF=$(CI_IMAGE_ROOT="$FX" bash "$CIMG" ref)
[[ "$REF" =~ ^ghcr\.io/example-org/cromford-ci:[0-9a-f]{12}$ ]] && [ "$REF" = "ghcr.io/example-org/cromford-ci:$T_FX" ] && ok || bad "T4: ref '$REF' has the wrong form"
rm -f "$FX/worker/jobs/package-lock.json"
CI_IMAGE_ROOT="$FX" bash "$CIMG" tag >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && ok || bad "T5: a missing input must be rc 2, got $rc"
cp "$DIR/worker/jobs/package-lock.json" "$FX/worker/jobs/package-lock.json"

# ── M: the switch ───────────────────────────────────────────────────────────
mode() { CI_IMAGE_VAR="$1" CI_IMAGE_LABEL="$2" bash "$CIMG" mode 2>/dev/null; }
[ "$(mode on false)" = image ] && ok || bad "M1: CI_IMAGE=on must be image"
[ "$(mode on '')" = image ] && ok || bad "M1: CI_IMAGE=on with no label must be image"
[ "$(mode '' true)" = image ] && ok || bad "M2: the ci-image label with CI_IMAGE unset must be image"
[ "$(mode '' false)" = host ] && ok || bad "M3: CI_IMAGE unset, no label must be host"
[ "$(mode '' '')" = host ] && ok || bad "M3: CI_IMAGE unset, label empty (a push) must be host"
[ "$(env -u CI_IMAGE_VAR -u CI_IMAGE_LABEL bash "$CIMG" mode 2>/dev/null)" = host ] && ok || bad "M3: no switch env at all must be host"
[ "$(mode off true)" = host ] && ok || bad "M4: CI_IMAGE=off must be host even with the label"
for v in ON On true 1 yes ' on' 'on ' $'on\n' image; do
  out=$(mode "$v" false); rc=$?
  [ "$rc" = 2 ] && [ -z "$out" ] && ok || bad "M5: CI_IMAGE='$v' must be rc 2 with no mode (rc=$rc out=$out)"
done
for l in yes 1 TRUE ci-image; do
  out=$(mode '' "$l"); rc=$?
  [ "$rc" = 2 ] && [ -z "$out" ] && ok || bad "M6: CI_IMAGE_LABEL='$l' must be rc 2 (rc=$rc out=$out)"
done

# ── E: ensure, against a stub docker ────────────────────────────────────────
# stub docker: logs argv; DOCKER_MANIFEST_RC / DOCKER_BUILD_RC / DOCKER_PUSH_RC
# / DOCKER_LOGIN_RC pick each verb's rc; build lists its context dir; login
# records what arrived on stdin.
SB="$T/stub"; mkdir -p "$SB"
cat > "$SB/docker" <<SH
#!$BASH_BIN
printf '%s\n' "\$*" >> "\$DOCKER_LOG"
case "\$1" in
  login)    cat > "\$DOCKER_LOG.stdin"; exit "\${DOCKER_LOGIN_RC:-0}" ;;
  manifest) exit "\${DOCKER_MANIFEST_RC:-0}" ;;
  build)    ctx="\${!#}"; (cd "\$ctx" && find . -type f | sed 's|^\./||' | LC_ALL=C sort) > "\$DOCKER_LOG.ctx"; exit "\${DOCKER_BUILD_RC:-0}" ;;
  push)     exit "\${DOCKER_PUSH_RC:-0}" ;;
esac
exit 0
SH
chmod +x "$SB/docker"
# ensure <case> <var> <label> [VAR=val ...] — runs in $T/e-<case>, sets OUT/LOG/GO/RC
ensure() {
  local c="$1" v="$2" l="$3"; shift 3
  E="$T/e-$c"; mkdir -p "$E"; LOG="$E/docker.log"; GO="$E/github_output"; : > "$LOG"; : > "$GO"
  OUT=$(env PATH="$SB:$PATH" DOCKER_LOG="$LOG" GITHUB_OUTPUT="$GO" CI_IMAGE_ROOT="$FX" \
        CI_IMAGE_VAR="$v" CI_IMAGE_LABEL="$l" "$@" bash "$CIMG" ensure 2>&1); RC=$?
}
ensure host '' false
[ "$RC" = 0 ] && [ ! -s "$LOG" ] && [ "$(cat "$GO")" = "ref=" ] && grep -q '^ci-image: host (CI_IMAGE unset)$' <<<"$OUT" && ok \
  || bad "E2: host mode must write ref= and call no docker (rc=$RC log=$(cat "$LOG") out=$OUT)"
ensure hostoff off true GHCR_USER=fixture-actor GHCR_TOKEN=tok-fixture-1
[ "$RC" = 0 ] && [ ! -s "$LOG" ] && [ "$(cat "$GO")" = "ref=" ] && ok || bad "E2: CI_IMAGE=off must be host, no docker, no login (log=$(cat "$LOG"))"
ensure present on false DOCKER_MANIFEST_RC=0
[ "$RC" = 0 ] && [ "$(cat "$GO")" = "ref=$REF" ] && grep -q "^ci-image: $REF (present" <<<"$OUT" \
  && [ "$(cut -d' ' -f1 "$LOG" | tr '\n' ' ')" = "manifest " ] && ok \
  || bad "E1: a present tag must write its ref and build nothing (rc=$RC log=$(cat "$LOG") out=$OUT)"
ensure built '' true DOCKER_MANIFEST_RC=1
[ "$RC" = 0 ] && [ "$(cat "$GO")" = "ref=$REF" ] && grep -q "^ci-image: $REF (built+pushed" <<<"$OUT" \
  && [ "$(cut -d' ' -f1 "$LOG" | tr '\n' ' ')" = "manifest build push " ] && ok \
  || bad "E4: a missing tag must be built then pushed, then written (rc=$RC log=$(cat "$LOG") out=$OUT)"
grep -q -- "-t $REF -f .*/ci-images/cromford/Dockerfile " "$LOG" && grep -q "^push $REF$" "$LOG" && ok || bad "E4: build/push must name the ref and the staged Dockerfile: $(cat "$LOG")"
[ "$(cat "$E/docker.log.ctx" 2>/dev/null)" = "$(bash "$CIMG" inputs)" ] && ok || bad "E4: the build context must be the inputs only: $(cat "$E/docker.log.ctx" 2>/dev/null)"
ensure buildfail on false DOCKER_MANIFEST_RC=1 DOCKER_BUILD_RC=1
[ "$RC" = 1 ] && [ ! -s "$GO" ] && grep -qF "::error::ci-image: $REF is missing and could not be built (docker build)" <<<"$OUT" \
  && ! grep -q '^push' "$LOG" && ok || bad "E3: a failed build must be rc 1 by name, no push, no ref (rc=$RC go=$(cat "$GO") out=$OUT)"
ensure pushfail on false DOCKER_MANIFEST_RC=1 DOCKER_PUSH_RC=1
[ "$RC" = 1 ] && [ ! -s "$GO" ] && grep -qF "(docker push)" <<<"$OUT" && ok || bad "E3: a failed push must be rc 1 by name, no ref (rc=$RC out=$OUT)"
ensure login on false GHCR_USER=fixture-actor GHCR_TOKEN=tok-fixture-1 DOCKER_MANIFEST_RC=0
[ "$RC" = 0 ] && grep -q '^login ghcr.io -u fixture-actor --password-stdin$' "$LOG" && [ "$(cat "$LOG.stdin")" = tok-fixture-1 ] \
  && ! grep -q 'tok-fixture-1' "$LOG" && ok || bad "E5: login must pass the token on stdin, never argv (log=$(cat "$LOG"))"
ensure loginfail on false GHCR_USER=fixture-actor GHCR_TOKEN=tok-fixture-1 DOCKER_LOGIN_RC=1
[ "$RC" = 1 ] && [ ! -s "$GO" ] && grep -qF "(docker login ghcr.io)" <<<"$OUT" && ! grep -q '^manifest' "$LOG" && ok \
  || bad "E5: a failed login must be rc 1 by name before the registry is asked (rc=$RC log=$(cat "$LOG"))"
ensure badvar ON false
[ "$RC" = 2 ] && [ ! -s "$LOG" ] && [ ! -s "$GO" ] && ok || bad "E6: a bad switch value must be rc 2, no docker, no ref (rc=$RC)"
# no docker anywhere on PATH: a bin dir of just the commands the script needs
ND="$T/nodocker"; mkdir -p "$ND"
for c in bash cat sha256sum cut dirname mktemp mkdir cp rm; do ln -s "$(command -v "$c")" "$ND/$c"; done
: > "$T/nd-go"
OUT=$(env -i PATH="$ND" GITHUB_OUTPUT="$T/nd-go" CI_IMAGE_ROOT="$FX" CI_IMAGE_VAR=on "$ND/bash" "$CIMG" ensure 2>&1); RC=$?
[ "$RC" = 1 ] && [ ! -s "$T/nd-go" ] && grep -qF "(no docker on this runner)" <<<"$OUT" && ok || bad "E7: image mode with no docker must be rc 1 by name (rc=$RC out=$OUT)"

# ── N + R1: ci-node-modules.sh ──────────────────────────────────────────────
NB="$T/n"; mkdir -p "$NB/bin"
printf '#!%s\necho "$*" >> "%s/npm.calls"\nexit 0\n' "$BASH_BIN" "$NB" > "$NB/bin/npm"; chmod +x "$NB/bin/npm"
# R1: the stamp lines the Dockerfile runs, extracted and executed here.
STAMPS=$(grep -E '> \.lock-sha256$' "$DF" | sed 's/^[[:space:]]*//')
[ "$(grep -c . <<<"$STAMPS")" = 2 ] && [ "$(sort -u <<<"$STAMPS" | grep -c .)" = 1 ] && ok \
  || bad "R1: the Dockerfile must stamp both trees with one identical line: $STAMPS"
STAMP=${STAMPS%%$'\n'*}
nfix() {  # nfix <case> -> $NC: a checkout pkg dir + a baked tree stamped by the Dockerfile's line
  NC="$NB/$1"; mkdir -p "$NC/co/worker/jobs" "$NC/baked/worker-jobs/node_modules"
  cp "$DIR/worker/jobs/package-lock.json" "$NC/co/worker/jobs/"
  cp "$DIR/worker/jobs/package-lock.json" "$NC/baked/worker-jobs/"
  (cd "$NC/baked/worker-jobs" && "$BASH_BIN" -c "$STAMP")
  echo marker > "$NC/baked/worker-jobs/node_modules/marker"
}
cnm() { (cd "$NC/co" && env PATH="$NB/bin:$PATH" CI_NODE_BAKED_ROOT="${NBAKED:-$NC/baked}" bash "$CNM" "$@") 2>&1; }
nfix n1; OUT=$(cnm worker/jobs worker-jobs); RC=$?
[ "$RC" = 0 ] && [ -L "$NC/co/worker/jobs/node_modules" ] && [ -f "$NC/co/worker/jobs/node_modules/marker" ] && ok \
  || bad "N1/R1: a matching lockfile must link the baked tree (rc=$RC out=$OUT)"
OUT=$(cnm worker/jobs worker-jobs); RC=$?
[ "$RC" = 0 ] && [ "$(readlink "$NC/co/worker/jobs/node_modules")" = "$NC/baked/worker-jobs/node_modules" ] && ok || bad "N5: a re-run must relink (rc=$RC out=$OUT)"
nfix n2; printf ' ' >> "$NC/co/worker/jobs/package-lock.json"; OUT=$(cnm worker/jobs worker-jobs); RC=$?
[ "$RC" = 1 ] && [ ! -e "$NC/co/worker/jobs/node_modules" ] && grep -q '^::error::ci-node-modules: worker-jobs: the baked tree is from lockfile' <<<"$OUT" && ok \
  || bad "N2: a lockfile mismatch must be rc 1 by name and link nothing (rc=$RC out=$OUT)"
nfix n3; OUT=$(NBAKED="$NC/no-baked-root" cnm worker/jobs worker-jobs); RC=$?
[ "$RC" = 1 ] && [ ! -e "$NC/co/worker/jobs/node_modules" ] && grep -q '::error::.*no baked tree' <<<"$OUT" && ok \
  || bad "N3: no baked tree must be rc 1 by name, never an install (rc=$RC out=$OUT)"
nfix n4; mkdir -p "$NC/co/worker/jobs/node_modules"; echo mine > "$NC/co/worker/jobs/node_modules/keep"
OUT=$(cnm worker/jobs worker-jobs); RC=$?
[ "$RC" = 1 ] && [ ! -L "$NC/co/worker/jobs/node_modules" ] && [ "$(cat "$NC/co/worker/jobs/node_modules/keep")" = mine ] && ok \
  || bad "N4: a real node_modules must be left as it is and be rc 1 (rc=$RC out=$OUT)"
for a in "" "worker/jobs" "worker/jobs Bad/Name" "a b c"; do
  # shellcheck disable=SC2086 # word splitting is the point: each case is an argv
  OUT=$(cnm $a); RC=$?
  [ "$RC" = 2 ] && ok || bad "N6: misuse '$a' must be rc 2, got $RC"
done
[ ! -e "$NB/npm.calls" ] && ok || bad "N: ci-node-modules.sh must never run npm: $(cat "$NB/npm.calls")"

echo "ci-image-use: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]
