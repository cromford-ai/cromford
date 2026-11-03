#!/bin/bash
# tests/ci-image-rollout.bh-7256-test.sh — the CI image rollout to the other
# fleet repos (BH-7256): the project-layer kit in ci-images/project-layer/ and
# bin/ci-image-rollout.sh, the filer that makes one child ticket per repo on
# that repo's own board.
#
#   K  the kit: ci-images/project-layer/ci-image.sh against a scratch checkout
#      and a stub docker (K1-K6), the Dockerfile (K7-K8), the workflow jobs (K9)
#   R  bin/ci-image-rollout.sh, run as shipped, against a fixture fleet.conf, a
#      stub gh and a stub curl (R1-R12); the sandbox rule (R13), the two knobs
#      (R14-R15), the --apply re-run warning (R16), the MonkCI caveat (R17),
#      the on-image verdict for a repo already on the image (R18)
#
# Offline. Run from anywhere: bash tests/ci-image-rollout.bh-7256-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
KIT="$DIR/ci-images/project-layer"
ROLL="$DIR/bin/ci-image-rollout.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
has() { grep -qF -- "$2" "$1"; }

for f in "$KIT/Dockerfile" "$KIT/ci-image.sh" "$KIT/ci-image.conf" "$KIT/ci-image-job.yml" "$KIT/child-ticket.md" "$ROLL"; do
  [ -r "$f" ] || { echo "FAIL: ci-image-rollout: missing $f"; exit 1; }
done
python3 -c 'import yaml' 2>/dev/null || { echo "FAIL: ci-image-rollout: python3 + PyYAML required"; exit 1; }
unset REGISTRY_SOURCE CI_IMAGE_VAR CI_IMAGE_LABEL GHCR_USER GHCR_TOKEN GITHUB_OUTPUT
unset CI_ROLLOUT_CURL_MAX_TIME CI_ROLLOUT_SEARCH_PER_PAGE LANE_REGISTRY LANE_GATE_DISABLE LANE_GATE_NOW

# ── K: the kit ci-image.sh, in a scratch checkout laid out as a child repo ──
CO="$T/co"
mkdir -p "$CO/ci"
cp "$KIT/ci-image.sh" "$CO/ci/ci-image.sh"; chmod 755 "$CO/ci/ci-image.sh"
cp "$KIT/Dockerfile" "$CO/ci/Dockerfile"
printf '{"name":"fixture"}\n' > "$CO/package.json"
printf '{"lockfileVersion":3}\n' > "$CO/package-lock.json"
printf 'not an input\n' > "$CO/README.md"
cat > "$CO/ci/ci-image.conf" <<'EOF'
# fixture conf
image=ghcr.io/example-org/fixture-repo-ci

input=package-lock.json
input=package.json
EOF
KS="$CO/ci/ci-image.sh"
kit() { CI_IMAGE_ROOT="$CO" "$KS" "$@"; }

# K1 inputs and ref read the conf; a missing conf is rc 2 by name
out=$(kit inputs); rc=$?
want=$(printf 'ci/Dockerfile\nci/ci-image.conf\npackage-lock.json\npackage.json')
[ "$rc" = 0 ] && [ "$out" = "$want" ] && ok || bad "K1 inputs: rc=$rc out=[$out]"
ref=$(kit ref); rc=$?
[[ "$ref" =~ ^ghcr\.io/example-org/fixture-repo-ci:[0-9a-f]{12}$ ]] && [ "$rc" = 0 ] && ok || bad "K1 ref uses image=: rc=$rc [$ref]"
t1=$(kit tag); echo changed > "$CO/README.md"; t2=$(kit tag)
[ "$t1" = "$t2" ] && ok || bad "K1 a file outside the inputs moved the tag"
printf '{"lockfileVersion":3,"x":1}\n' > "$CO/package-lock.json"; t3=$(kit tag)
[ "$t3" != "$t1" ] && ok || bad "K1 the lockfile did not move the tag"
mv "$CO/ci/ci-image.conf" "$CO/ci/conf.bak"
kit inputs >/dev/null 2>"$T/k1.err"; rc=$?
[ "$rc" = 2 ] && has "$T/k1.err" "ci/ci-image.conf" && ok || bad "K1 missing conf: rc=$rc $(cat "$T/k1.err")"
mv "$CO/ci/conf.bak" "$CO/ci/ci-image.conf"
for badconf in 'input=package.json' $'image=a\nimage=b' $'image=ghcr.io/x\ninput=../etc/passwd' $'image=ghcr.io/x\nfoo=bar' $'image=ghcr.io/X:latest'; do
  mkdir -p "$T/bc/ci"; printf '%s\n' "$badconf" > "$T/bc/ci/ci-image.conf"
  CI_IMAGE_ROOT="$T/bc" "$KS" inputs >/dev/null 2>&1; rc=$?
  [ "$rc" = 2 ] && ok || bad "K1 bad conf [$badconf] gave rc=$rc, want 2"
done

# K2 mode: the switch table
m() { CI_IMAGE_VAR="$1" CI_IMAGE_LABEL="$2" CI_IMAGE_ROOT="$CO" "$KS" mode 2>/dev/null; }
[ "$(m '' false)" = host ] && ok || bad "K2 unset = host"
[ "$(m '' true)" = image ] && ok || bad "K2 unset + label = image"
[ "$(m on false)" = image ] && ok || bad "K2 on = image"
[ "$(m off true)" = host ] && ok || bad "K2 off with label = host"
m ON false >/dev/null; rc=$?; [ "$rc" = 2 ] && ok || bad "K2 ON gave rc=$rc, want 2"

# A stub docker: each subcommand's rc from $T/dk/<sub>.rc, every call logged.
mkdir -p "$T/kbin" "$T/dk"
cat > "$T/kbin/docker" <<'EOF'
#!/bin/bash
echo "docker $*" >> "$DK/calls"
cat >/dev/null 2>&1 <&0 &
rc=$(cat "$DK/$1.rc" 2>/dev/null || echo 0)
exit "$rc"
EOF
chmod 755 "$T/kbin/docker"
ens() { : > "$T/dk/calls"; : > "$T/gho"; DK="$T/dk" PATH="$T/kbin:$PATH" GITHUB_OUTPUT="$T/gho" \
  CI_IMAGE_VAR="$1" CI_IMAGE_LABEL=false CI_IMAGE_ROOT="$CO" "$KS" ensure > "$T/ens.out" 2>&1; }
setrc() { echo "$2" > "$T/dk/$1.rc"; }
ref=$(kit ref)

# K3 the tag is present
setrc manifest 0; setrc build 0; setrc push 0
ens on; rc=$?
[ "$rc" = 0 ] && grep -qx "ref=$ref" "$T/gho" && ! grep -q 'docker build' "$T/dk/calls" && ok \
  || bad "K3 present: rc=$rc gho=$(cat "$T/gho") calls=$(cat "$T/dk/calls")"

# K4 missing tag, build and push work
setrc manifest 1
ens on; rc=$?
nb=$(grep -c '^docker build' "$T/dk/calls"); np=$(grep -c '^docker push' "$T/dk/calls")
[ "$rc" = 0 ] && [ "$nb" = 1 ] && [ "$np" = 1 ] && grep -qx "ref=$ref" "$T/gho" && ok \
  || bad "K4 build+push: rc=$rc build=$nb push=$np gho=$(cat "$T/gho")"
grep -q -- "-f /.*/ci/Dockerfile" "$T/dk/calls" && ok || bad "K4 the build must use the staged ci/Dockerfile: $(cat "$T/dk/calls")"

# K5 missing tag, push fails: red by name, no ref
setrc push 1
ens on; rc=$?
[ "$rc" = 1 ] && grep -qxF "::error::ci-image: $ref is missing and could not be built (docker push)" "$T/ens.out" \
  && ! grep -q '^ref=' "$T/gho" && ok || bad "K5 push fails: rc=$rc out=$(cat "$T/ens.out") gho=$(cat "$T/gho")"
setrc push 0; setrc build 1
ens on; rc=$?
[ "$rc" = 1 ] && has "$T/ens.out" "(docker build)" && ! grep -q '^ref=' "$T/gho" && ok || bad "K5 build fails: rc=$rc"
setrc build 0

# K6 host mode calls no docker and writes an empty ref
ens ''; rc=$?
[ "$rc" = 0 ] && [ ! -s "$T/dk/calls" ] && grep -qx 'ref=' "$T/gho" && ok || bad "K6 host: rc=$rc calls=$(cat "$T/dk/calls")"
ens ON; rc=$?
[ "$rc" = 2 ] && [ ! -s "$T/dk/calls" ] && ok || bad "K6 bad switch: rc=$rc"

# K7 + K8 the Dockerfile
DF="$KIT/Dockerfile"
code=$(grep -v '^[[:space:]]*#' "$DF")
first_from=$(awk '/^FROM/{print $2; exit}' <<< "$code")
[ "$first_from" = '${CI_BASE}' ] && ok || bad "K7 first FROM must be \${CI_BASE}: [$first_from]"
def=$(printf '%s\n' "$code" | sed -n 's/^ARG CI_BASE=//p')
[[ "$def" =~ ^ghcr\.io/example-org/ci-base:[0-9a-f]{12}$ ]] && ok || bad "K7 CI_BASE default must pin a :<sha12>: [$def]"
grep -q ':latest' <<< "$code" && bad "K7 the kit Dockerfile names :latest" || ok
stamp='sha256sum package-lock.json | cut -d'"' '"' -f1 > .lock-sha256'
bh=$(grep -F -- "$stamp" "$DIR/ci-images/cromford/Dockerfile" | head -1 | sed 's/^[[:space:]]*//')
kt=$(grep -F -- "$stamp" "$DF" | sed 's/^[[:space:]]*//')
[ -n "$bh" ] && [ "$kt" = "$bh" ] && ok || bad "K7 .lock-sha256 line differs from cromford's: [$kt] vs [$bh]"
grep -Eq '^COPY .*package-lock\.json ' <<< "$code" && ok || bad "K8 the kit Dockerfile must COPY a lockfile"
# Every COPY source is a kit conf input (else the image changes without its tag).
srcs=$(printf '%s\n' "$code" | awk '/^COPY/{for(i=2;i<NF;i++) print $i}' | sort -u)
ins=$(sed -n 's/^input=//p' "$KIT/ci-image.conf" | sort -u)
[ "$srcs" = "$ins" ] && ok || bad "K8 COPY sources [$srcs] must equal the kit conf inputs [$ins]"

# K9 the workflow jobs
PYOUT=$(python3 - "$KIT/ci-image-job.yml" <<'PY'
import sys, yaml
jobs = yaml.safe_load(open(sys.argv[1]))["jobs"]
REF = "${{ needs.ci-image.outputs.ref }}"
HOST = "needs.ci-image.outputs.ref == ''"
RUNNER = "${{ fromJSON(vars.CI_RUNNER || '\"ubuntu-latest\"') }}"
def bad(m): print("BAD " + m)
ci = jobs.get("ci-image") or {}
steps = ci.get("steps") or []
print("OK") if any("ci/ci-image.sh ensure" in (s.get("run") or "") for s in steps) else bad("ci-image job must run ci/ci-image.sh ensure")
print("OK") if (ci.get("outputs") or {}).get("ref") == "${{ steps.ensure.outputs.ref }}" else bad("ci-image must output ref")
print("OK") if (ci.get("permissions") or {}).get("packages") == "write" else bad("ci-image needs packages: write")
tests = [n for n in jobs if n != "ci-image"]
print("OK") if tests else bad("no test job")
for n in ["ci-image"] + tests:
    print("OK") if jobs[n].get("runs-on") == RUNNER else bad(f"{n} runs-on must read vars.CI_RUNNER")
for n in tests:
    j = jobs[n]
    print("OK") if "ci-image" in (j.get("needs") or []) else bad(f"{n} must need ci-image")
    print("OK") if (j.get("container") or {}).get("image") == REF else bad(f"{n} container.image must be {REF}")
    print("OK") if (j.get("permissions") or {}).get("packages") == "read" else bad(f"{n} needs packages: read")
    for s in j.get("steps") or []:
        txt = (s.get("uses") or "") + " " + (s.get("run") or "")
        if "setup-node" in txt or "npm ci" in txt or "playwright install" in txt:
            print("OK") if s.get("if") == HOST else bad(f"{n}: install step {txt.strip()[:40]!r} must carry if: {HOST}")
    link = [s for s in j.get("steps") or [] if "/opt/ci/node/app/node_modules" in (s.get("run") or "")]
    print("OK") if link and link[0].get("if") == "needs.ci-image.outputs.ref != ''" else bad(f"{n}: no image-only link step")
PY
)
while IFS= read -r l; do case "$l" in OK) ok ;; BAD*) bad "K9 ${l#BAD }" ;; esac; done <<< "$PYOUT"
[ -n "$PYOUT" ] || bad "K9 the yaml check printed nothing"

# ── R: bin/ci-image-rollout.sh ───────────────────────────────────────────────
FX="$T/fx"; mkdir -p "$FX" "$T/rbin" "$T/h" "$T/env"
cat > "$T/fleet.conf" <<'EOF'
# fixture fleet.conf
alpha-os      Fixture/alpha-os      https://alpha.example.test  /api/board  1 box-a 192.0.2.1
beta          Fixture/beta          -                           -           2 box-b 192.0.2.2
gamma         Fixture/gamma         -                           -           3 box-b 192.0.2.2
cromford Fixture/bh-fork       -                           -           3 box-c 192.0.2.3
project-6-os  example-org/project-6   https://mk.example.test     -           1 box-d 192.0.2.4
mk-renamed    example-org/project-6   -                           -           1 box-d 192.0.2.4
cromford-x Fixture/cromford-x -                       -           4 box-c 192.0.2.3
cromford-sbx-linear Fixture/cromford-sandbox-linear -               -           5 box-e 192.0.2.5
cromford-sbx-jira Fixture/cromford-sandbox-jira -                   -           5 box-e 192.0.2.5
EOF
cat > "$T/env/alpha-os.env" <<'EOF'
ALPHA_INTERNAL_API_TOKEN=tok-fixture-alpha-7256
ALPHA_API_BASE=https://alpha.example.test
EOF
# Stub gh: answers from $FX, keyed by the repo slug (/ -> _). Logs every call.
cat > "$T/rbin/gh" <<'EOF'
#!/bin/bash
echo "gh $*" >> "$FX/calls"
[ "$1" = api ] || exit 9
shift
method=GET; path=""; q=""
while [ $# -gt 0 ]; do
  case "$1" in
    -X) method="$2"; shift 2 ;;
    -f|-F) case "$2" in q=*) q="${2#q=}" ;; body=@*) cp "${2#body=@}" "$FX/last-body" ;; esac; shift 2 ;;
    *) path="$1"; shift ;;
  esac
done
reply() { # reply <file stem>
  [ -f "$1.err" ] && cat "$1.err" >&2
  [ -f "$1" ] && cat "$1"
  exit "$(cat "$1.rc" 2>/dev/null || echo 0)"
}
case "$method $path" in
  "GET search/issues") r=$(printf '%s' "$q" | sed -E 's/^repo:([^ ]+) .*/\1/'); reply "$FX/search/${r//\//_}" ;;
  "POST repos/"*/issues) r=${path#repos/}; r=${r%/issues}; echo "CREATE gh $r" >> "$FX/creates"; reply "$FX/create/${r//\//_}" ;;
  "GET repos/"*/contents/.github/workflows) r=${path#repos/}; r=${r%/contents/.github/workflows}; reply "$FX/contents/${r//\//_}" ;;
  # ci/ci-image.conf: absent (HTTP 404) unless a fixture says otherwise.
  "GET repos/"*/contents/ci/ci-image.conf) r=${path#repos/}; r=${r%/contents/ci/ci-image.conf}; r="$FX/conf/${r//\//_}"
    [ -f "$r" ] || { echo 'gh: Not Found (HTTP 404)' >&2; exit 1; }; reply "$r" ;;
  "GET repos/"*) r=${path#repos/}; reply "$FX/repo/${r//\//_}" ;;
esac
exit 9
EOF
# Stub curl: answers from $FX/http/<METHOD>_<url with / and : as _>, code in .code.
cat > "$T/rbin/curl" <<'EOF'
#!/bin/bash
method=GET; out=""; url=""; hdr=""; data=""; mt=none
while [ $# -gt 0 ]; do
  case "$1" in
    -X) method="$2"; shift 2 ;;
    -o) out="$2"; shift 2 ;;
    -H) case "$2" in @*) hdr="${2#@}" ;; esac; shift 2 ;;
    --data-binary) data="${2#@}"; shift 2 ;;
    --max-time) mt="$2"; shift 2 ;;
    -w) shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
auth=no; [ -n "$hdr" ] && grep -q '^Authorization: Bearer tok-fixture-' "$hdr" && auth=yes
echo "curl $method $url auth=$auth mt=$mt" >> "$FX/calls"
k="$method"_$(printf '%s' "$url" | tr '/:' '__')
[ "$method" = POST ] && { echo "CREATE app $url" >> "$FX/creates"; [ -n "$data" ] && cp "$data" "$FX/last-payload"; }
if [ -f "$FX/http/$k" ]; then cat "$FX/http/$k" > "${out:-/dev/stdout}"; else : > "${out:-/dev/stdout}"; fi
printf '%s' "$(cat "$FX/http/$k.code" 2>/dev/null || echo 404)"
EOF
chmod 755 "$T/rbin/gh" "$T/rbin/curl"

roll() { : > "$FX/calls"; : > "$FX/creates"; rm -f "$FX/last-body" "$FX/last-payload"
  FX="$FX" PATH="$T/rbin:$PATH" HARNESS="$T/h" HARNESS_ENV_DIR="$T/env" FLEET_CONF="${FC:-$T/fleet.conf}" \
    "$ROLL" "$@" > "$T/r.out" 2> "$T/r.err"; }
# fixture writers
put() { mkdir -p "$(dirname "$1")"; rm -f "$1.rc" "$1.err"; printf '%s\n' "$2" > "$1"; [ -n "${3:-}" ] && echo "$3" > "$1.rc"; [ -n "${4:-}" ] && printf '%s\n' "$4" > "$1.err"; return 0; }
reset_fx() { local d; for d in contents repo search create http conf; do scratch_rm "$T/fx/$d"; done; mkdir -p "$FX/search"; }
APPB=https://alpha.example.test/api/board
http() { mkdir -p "$FX/http"; local k; k="$1"_$(printf '%s' "$2" | tr '/:' '__'); printf '%s\n' "$3" > "$FX/http/$k"; echo "${4:-200}" > "$FX/http/$k.code"; }
EMPTY_SEARCH='{"total_count":0,"incomplete_results":false,"items":[]}'
yml() { put "$FX/contents/$1" '[{"name":"ci.yml","type":"file"}]'; }

# R1 targets: every fleet project but the sandboxes. No project is out by its
# name: cromford, project-6-os and mk-renamed are in (R18 decides them).
roll targets; rc=$?
got=$(cut -f1 "$T/r.out" | paste -sd' ' -)
[ "$rc" = 0 ] && [ "$got" = "alpha-os beta gamma cromford project-6-os mk-renamed cromford-x" ] && ok || bad "R1 targets: rc=$rc [$got]"
grep -qP '^alpha-os\tFixture/alpha-os\tapp$' "$T/r.out" && grep -qP '^beta\tFixture/beta\tgh$' "$T/r.out" && ok || bad "R1 kind column: $(cat "$T/r.out")"

# R2 the runs-CI decision table (plan, one target at a time)
verdict() { roll plan "$1"; cut -f4 "$T/r.out"; }
reset_fx
yml Fixture_beta; put "$FX/search/Fixture_beta" "$EMPTY_SEARCH"
[ "$(verdict beta)" = runs-ci ] && ok || bad "R2 ci.yml = runs-ci: $(cat "$T/r.out" "$T/r.err")"
put "$FX/contents/Fixture_beta" '[{"name":"test.yaml","type":"file"}]'
[ "$(verdict beta)" = runs-ci ] && ok || bad "R2 test.yaml = runs-ci"
put "$FX/contents/Fixture_beta" '[{"name":"README.md","type":"file"},{"name":"ci.yml.disabled","type":"file"}]'
[ "$(verdict beta)" = no-ci ] && ok || bad "R2 README.md + ci.yml.disabled = no-ci: $(cat "$T/r.out")"
put "$FX/contents/Fixture_beta" '{"message":"Not Found"}' 1 'gh: Not Found (HTTP 404)'; put "$FX/repo/Fixture_beta" '{"full_name":"Fixture/beta"}'
[ "$(verdict beta)" = no-ci ] && ok || bad "R2 404 path on a readable repo = no-ci: $(cat "$T/r.out")"
put "$FX/repo/Fixture_beta" '{"message":"Not Found"}' 1 'gh: Not Found (HTTP 404)'
v=$(verdict beta); rc=$?
[ "$v" = "unknown repo-unreadable" ] && ok || bad "R2 repo 404 = unknown: [$v]"
roll plan beta; [ "$?" = 1 ] && ok || bad "R2 an unknown verdict must be rc 1"
put "$FX/contents/Fixture_beta" '{"message":"Forbidden"}' 1 'gh: Forbidden (HTTP 403)'
[ "$(verdict beta)" = "unknown gh-403" ] && ok || bad "R2 403 = unknown gh-403: $(cat "$T/r.out")"
put "$FX/contents/Fixture_beta" '' 0
[ "$(verdict beta)" = "unknown empty-answer" ] && ok || bad "R2 empty stdout rc 0 = unknown: $(cat "$T/r.out")"
! grep -q 'search/issues' "$FX/calls" && ok || bad "R2 no dedup read for an undecided repo"

# R3 the rendered body
roll body beta; rc=$?
B="$T/r.out"
[ "$rc" = 0 ] && tail -1 "$B" | grep -qx 'ci-image-rollout-of: BH-7256 repo=Fixture/beta' && ok || bad "R3 marker last line: rc=$rc"
has "$B" '"monkci-ubuntu-24.04-4"' && ok || bad "R3 MonkCI value"
grep -q '@@' "$B" && bad "R3 a placeholder is left: $(grep '@@' "$B")" || ok
for f in Dockerfile ci-image.sh ci-image-job.yml; do
  python3 - "$KIT/$f" "$B" <<'PY' && ok || bad "R3 kit $f is not inline verbatim"
import sys; sys.exit(0 if open(sys.argv[1]).read() in open(sys.argv[2]).read() else 1)
PY
done
has "$B" 'image=ghcr.io/example-org/beta-ci' && ! has "$B" 'REPLACE-WITH' && ok || bad "R3 the conf image= is set for the repo"
has "$B" 'Fixture/cromford#7256' || has "$B" 'example-org/cromford#7256' && ok || bad "R3 report back to the parent"
[ "$(sed -n '/^```bash$/,/^```$/p' "$B" | sed '1d;$d')" = "$(cat "$KIT/ci-image.sh")" ] && ok || bad "R3 the bash fence holds exactly the kit script"

# R4 round trip: an issue whose body is R3's output is already filed
cp "$B" "$T/body-beta.md"
reset_fx; yml Fixture_beta
jq -n --rawfile b "$T/body-beta.md" '{total_count:1, incomplete_results:false, items:[{number:41, state:"closed", body:$b}]}' > "$FX/search/Fixture_beta"
roll file beta --apply; rc=$?
[ "$rc" = 0 ] && grep -qx 'already-filed beta Fixture/beta#41' "$T/r.out" && [ ! -s "$FX/creates" ] && ok \
  || bad "R4 a closed issue with the marker = already-filed, no create: rc=$rc out=$(cat "$T/r.out") creates=$(cat "$FX/creates")"

# R5 a create answer with no number
reset_fx; yml Fixture_beta; put "$FX/search/Fixture_beta" "$EMPTY_SEARCH"
put "$FX/create/Fixture_beta" '{"message":"Validation Failed"}' 1
roll file beta --apply; rc=$?
[ "$rc" = 1 ] && grep -q '^create-failed beta ' "$T/r.out" && ! grep -q '^filed' "$T/r.out" && ok || bad "R5 no number = create-failed rc 1: rc=$rc $(cat "$T/r.out")"
put "$FX/create/Fixture_beta" '{"html_url":"https://github.example.test/x"}' 0
roll file beta --apply; rc=$?
[ "$rc" = 1 ] && grep -q '^create-failed beta ' "$T/r.out" && ok || bad "R5 rc 0 but no number = create-failed: rc=$rc $(cat "$T/r.out")"

# R6 a rate limit is unknown, never no-ci
reset_fx; put "$FX/contents/Fixture_beta" '' 75 'gh: rate limited'
roll file beta --apply; rc=$?
[ "$rc" = 1 ] && grep -qx 'unknown beta Fixture/beta rate-limited' "$T/r.out" && [ ! -s "$FX/creates" ] && ok || bad "R6 gh rc 75: rc=$rc $(cat "$T/r.out")"
reset_fx; put "$FX/contents/Fixture_beta" '{"message":"Not Found"}' 1 'gh: Not Found (HTTP 404)'; put "$FX/repo/Fixture_beta" '' 75
[ "$(verdict beta)" = "unknown rate-limited" ] && ok || bad "R6 rc 75 on the repo read: $(cat "$T/r.out")"

# R7 a failed or incomplete dedup read refuses the project
reset_fx; yml Fixture_beta; put "$FX/search/Fixture_beta" '' 1 'gh: Server Error (HTTP 502)'
roll file beta --apply; rc=$?
[ "$rc" = 1 ] && grep -qx 'unknown beta Fixture/beta dedup-read-failed' "$T/r.out" && [ ! -s "$FX/creates" ] && ok || bad "R7 failed search: rc=$rc $(cat "$T/r.out")"
put "$FX/search/Fixture_beta" '{"total_count":0,"incomplete_results":true,"items":[]}'
roll file beta --apply; rc=$?
[ "$rc" = 1 ] && has "$T/r.out" dedup-read-failed && [ ! -s "$FX/creates" ] && ok || bad "R7 incomplete search: rc=$rc $(cat "$T/r.out")"
put "$FX/search/Fixture_beta" 'not json'
roll file beta --apply; [ "$?" = 1 ] && [ ! -s "$FX/creates" ] && ok || bad "R7 unparseable search"
reset_fx; put "$FX/contents/Fixture_alpha-os" '[{"name":"ci.yml","type":"file"}]'
http GET "$APPB/boards" '{"boards":[{"id":"b1"}]}'
http GET "$APPB/boards/b1/tickets" 'oops' 500
roll file alpha-os --apply; rc=$?
[ "$rc" = 1 ] && has "$T/r.out" 'dedup-read-failed' && [ ! -s "$FX/creates" ] && ok || bad "R7 app list 500: rc=$rc $(cat "$T/r.out")"

# R8 file --all --apply: two GitHub targets and one app target; two repos
# already on the image (a ci-image.yml workflow, a ci/ci-image.conf) and one
# with no CI get a line and no read past the verdict.
reset_fx
for r in Fixture_alpha-os Fixture_beta Fixture_gamma Fixture_cromford-x example-org_project-6; do yml "$r"; done
put "$FX/contents/Fixture_bh-fork" '[{"name":"ci.yml","type":"file"},{"name":"ci-image.yml","type":"file"}]'
put "$FX/conf/example-org_project-6" '{"name":"ci-image.conf","path":"ci/ci-image.conf","type":"file","content":"aW1hZ2U9Cg=="}'
put "$FX/contents/example-org_project-6" '[{"name":"README.md","type":"file"}]'
put "$FX/repo/Fixture_cromford-x" '{}'
put "$FX/contents/Fixture_cromford-x" '{"message":"Not Found"}' 1 'gh: Not Found (HTTP 404)'
for r in Fixture_beta Fixture_gamma; do put "$FX/search/$r" "$EMPTY_SEARCH"; done
put "$FX/create/Fixture_beta" '{"number":101,"html_url":"https://github.example.test/b/101"}'
put "$FX/create/Fixture_gamma" '{"number":7}'
http GET "$APPB/boards" '{"boards":[{"id":"b1"},{"id":"b2"}]}'
http GET "$APPB/boards/b1/tickets" '{"tickets":[{"id":"t1","title":"something else","description":"ci-image-rollout-of: BH-7255 repo=Fixture/alpha-os"}]}'
http POST "$APPB/boards/b1/tickets" '{"ticket":{"id":"t9","key":"AL-9"}}' 201
roll file --all --apply; rc=$?
[ "$rc" = 0 ] && ok || bad "R8 rc=$rc out=$(cat "$T/r.out") err=$(cat "$T/r.err")"
[ "$(wc -l < "$FX/creates")" = 3 ] && ok || bad "R8 want 3 creates: $(cat "$FX/creates")"
grep -qx 'filed alpha-os AL-9' "$T/r.out" && grep -qx 'filed beta Fixture/beta#101' "$T/r.out" && grep -qx 'filed gamma Fixture/gamma#7' "$T/r.out" \
  && grep -qx 'no-ci cromford-x Fixture/cromford-x' "$T/r.out" && ok || bad "R8 per-target lines: $(cat "$T/r.out")"
grep -qx 'on-image cromford Fixture/bh-fork' "$T/r.out" && grep -qx 'on-image project-6-os example-org/project-6' "$T/r.out" \
  && grep -qx 'no-ci mk-renamed example-org/project-6' "$T/r.out" && ok || bad "R8 on-image and no-ci lines: $(cat "$T/r.out")"
calls=$(cat "$FX/calls")
grep -qE 'repo:(Fixture/bh-fork|example-org/project-6) |repos/(Fixture/bh-fork|example-org/project-6)/issues' <<<"$calls" \
  && bad "R8 an on-image repo got a search or a create: $calls" || ok
grep -q 'repos/Fixture/beta/issues .*labels\[\]=ai-build' "$FX/calls" && grep -q 'repos/Fixture/gamma/issues .*labels\[\]=ai-build' "$FX/calls" && ok \
  || bad "R8 GitHub creates carry the ai-build label: $(grep POST "$FX/calls")"
grep -qx "CREATE app $APPB/boards/b1/tickets" "$FX/creates" && ok || bad "R8 app create posts to <base>/boards/<first id>/tickets"
grep -q "^curl POST $APPB/boards/b1/tickets auth=yes" "$FX/calls" && ok || bad "R8 app create sends the bearer header"
jq -e --arg t 'CI images: run Fixture/alpha-os CI on the prebuilt image (BH-7256 slice 4)' \
  '.title == $t and (.description | test("ci-image-rollout-of: BH-7256 repo=Fixture/alpha-os\n?$"))' "$FX/last-payload" >/dev/null && ok \
  || bad "R8 app payload title and marker: $(head -c 300 "$FX/last-payload")"

# R9 marker near misses
reset_fx; yml Fixture_beta
near() { jq -n --arg b "$1" '{total_count:1, incomplete_results:false, items:[{number:5, body:$b}]}' > "$FX/search/Fixture_beta"; roll plan beta; cut -f4 "$T/r.out"; }
[ "$(near 'see ci-image-rollout-of: BH-7255 repo=Fixture/beta')" = runs-ci ] && ok || bad "R9 a BH-7255 marker is not a match"
[ "$(near $'x\nci-image-rollout-of: BH-7256 repo=Fixture/project-3')" = runs-ci ] && ok || bad "R9 another repo's marker is not a match"
[ "$(near $'x\nci-image-rollout-of: BH-7256 repo=Fixture/beta-two')" = runs-ci ] && ok || bad "R9 a longer repo name is not a match"
[ "$(near 'mentions ci-image-rollout-of without the key')" = runs-ci ] && ok || bad "R9 the bare word is not a match"
[ "$(near $'x\nci-image-rollout-of: BH-7256 repo=Fixture/beta')" = "filed Fixture/beta#5" ] && ok || bad "R9 the exact marker line matches: $(cat "$T/r.out")"
reset_fx; put "$FX/contents/Fixture_alpha-os" '[{"name":"ci.yml","type":"file"}]'
http GET "$APPB/boards" '[{"id":"b1"}]'
http GET "$APPB/boards/b1/tickets" '[{"id":"t3","key":"AL-3","title":"CI images: run Fixture/alpha-os CI on the prebuilt image (BH-7256 slice 4)"}]'
roll plan alpha-os
[ "$(cut -f4 "$T/r.out")" = "filed AL-3" ] && ok || bad "R9 app row with the child title and no description matches: $(cat "$T/r.out" "$T/r.err")"
http GET "$APPB/boards/b1/tickets" '[{"id":"t4","key":"AL-4","title":"x","description":"<p>ci-image-rollout-of: BH-7256 repo=Fixture/alpha-os</p>"}]'
roll plan alpha-os
[ "$(cut -f4 "$T/r.out")" = "filed AL-4" ] && ok || bad "R9 app HTML description with the marker matches: $(cat "$T/r.out")"

# R10 a dry run files nothing; a repo on the image prints on-image
reset_fx
for r in Fixture_alpha-os Fixture_beta Fixture_gamma Fixture_cromford-x example-org_project-6; do yml "$r"; done
for r in Fixture_beta Fixture_gamma Fixture_cromford-x; do put "$FX/search/$r" "$EMPTY_SEARCH"; done
put "$FX/contents/Fixture_bh-fork" '[{"name":"ci-image.yaml","type":"file"},{"name":"test.yaml","type":"file"}]'
put "$FX/conf/example-org_project-6" '{"name":"ci-image.conf","type":"file","content":"aW1hZ2U9Cg=="}'
put "$FX/contents/example-org_project-6" '[]'
http GET "$APPB/boards" '{"boards":[{"id":"b1"}]}'
http GET "$APPB/boards/b1/tickets" '{"tickets":[]}'
roll file --all; rc=$?
[ "$rc" = 0 ] && [ "$(grep -c '^would file ' "$T/r.out")" = 4 ] && [ ! -s "$FX/creates" ] && ! grep -q 'POST' "$FX/calls" && ok \
  || bad "R10 dry run: rc=$rc out=$(cat "$T/r.out") creates=$(cat "$FX/creates")"
grep -qx 'would file beta Fixture/beta :: CI images: run Fixture/beta CI on the prebuilt image (BH-7256 slice 4)' "$T/r.out" && ok || bad "R10 would-file line and title"
grep -qx 'on-image cromford Fixture/bh-fork' "$T/r.out" && grep -qx 'on-image project-6-os example-org/project-6' "$T/r.out" && ok \
  || bad "R10 dry run prints on-image: $(cat "$T/r.out")"

# R11 misuse: rc 2 and no network call
for args in "file" "file --apply" "bogus" "" "body" "plan a b" "file beta gamma" "file --nope"; do
  # shellcheck disable=SC2086 # word-split the argument list on purpose
  roll $args; rc=$?
  [ "$rc" = 2 ] && [ ! -s "$FX/calls" ] && ok || bad "R11 misuse [$args]: rc=$rc calls=$(cat "$FX/calls")"
done
roll body nosuch-project; rc=$?
[ "$rc" = 2 ] && ok || bad "R11 a project absent from the fleet is not a target: rc=$rc"
roll file nosuch-project --apply; rc=$?
[ "$rc" = 2 ] && [ ! -s "$FX/calls" ] && ok || bad "R11 file on a project absent from the fleet: rc=$rc calls=$(cat "$FX/calls")"

# R12 the token never reaches stdout or stderr, even on a failed create
reset_fx; put "$FX/contents/Fixture_alpha-os" '[{"name":"ci.yml","type":"file"}]'
http GET "$APPB/boards" '{"boards":[{"id":"b1"}]}'
http GET "$APPB/boards/b1/tickets" '[]'
http POST "$APPB/boards/b1/tickets" '{"error":"nope"}' 500
roll file alpha-os --apply; rc=$?
[ "$rc" = 1 ] && grep -q '^create-failed alpha-os ' "$T/r.out" && ok || bad "R12 create 500 = create-failed: rc=$rc $(cat "$T/r.out")"
for f in "$T/r.out" "$T/r.err"; do has "$f" 'tok-fixture-alpha' && bad "R12 the token is in $(basename "$f")" || ok; done
roll plan --all; for f in "$T/r.out" "$T/r.err"; do has "$f" 'tok-fixture-alpha' && bad "R12 plan printed the token" || ok; done
rm -f "$T/env/alpha-os.env"
roll plan alpha-os; [ "$(cut -f4 "$T/r.out")" = "unknown no-env-file" ] && ok || bad "R12 no env file = unknown: $(cat "$T/r.out")"
[ ! -s "$T/h/logs/ALERTS.log" ] && ok || bad "R12 the filer wrote an ALERTS line"

# R12 removed the app board's env file; R14-R16 need it back.
printf '%s\n' ALPHA_INTERNAL_API_TOKEN=tok-fixture-alpha-7256 ALPHA_API_BASE=https://alpha.example.test > "$T/env/alpha-os.env"

# R13 the sandbox rule: a project name with the dash token `sbx`, or a repo
# name holding `sandbox` (any case), is never a target. Near misses stay in.
cat > "$T/fleet-sbx.conf" <<'EOF'
cromford-sbx-linear Fixture/cromford-sandbox-linear - - 5 box-e 192.0.2.5
cromford-sbx-jira   Fixture/cromford-sandbox-jira   - - 5 box-e 192.0.2.5
foo                 Fixture/Foo-Sandbox             - - 5 box-e 192.0.2.5
sbx-demo            Fixture/demo                    - - 5 box-e 192.0.2.5
cromford            Fixture/cromford-web            - - 5 box-e 192.0.2.5
sbxtools            Fixture/sbxtools                - - 5 box-e 192.0.2.5
project-2       Fixture/project-2           - - 5 box-e 192.0.2.5
project-6-desktop   Fixture/project-6-desktop       - - 5 box-e 192.0.2.5
EOF
FC="$T/fleet-sbx.conf" roll targets; rc=$?
got=$(cut -f1 "$T/r.out" | paste -sd' ' -)
[ "$rc" = 0 ] && [ "$got" = "cromford sbxtools project-2 project-6-desktop" ] && ok || bad "R13 sandbox rule: rc=$rc [$got]"
FC="$T/fleet-sbx.conf" roll file cromford-sbx-linear --apply; rc=$?
[ "$rc" = 2 ] && [ ! -s "$FX/calls" ] && ok || bad "R13 a sandbox project is not a target: rc=$rc calls=$(cat "$FX/calls")"
roll targets; out=$(cat "$T/r.out")
grep -q sbx <<<"$out" && bad "R13 the main fixture printed a sandbox row: $out" || ok

# R14 the knob defaults: curl --max-time 25, search per_page=100
k_reads() { # k_reads [ENV=VAL ...] — one app-board plan and one GitHub plan
  reset_fx; yml Fixture_alpha-os; yml Fixture_beta; put "$FX/search/Fixture_beta" "$EMPTY_SEARCH"
  http GET "$APPB/boards" '{"boards":[{"id":"b1"}]}'; http GET "$APPB/boards/b1/tickets" '[]'
  ( for kv in "$@"; do export "${kv?}"; done; roll plan alpha-os; cp "$FX/calls" "$T/k.app"; roll plan beta; cp "$FX/calls" "$T/k.gh" )
}
mt_of() { grep '^curl ' "$T/k.app" | sed -n 's/.* mt=//p' | sort -u | paste -sd, -; }
pp_of() { grep 'search/issues' "$T/k.gh" | grep -o 'per_page=[^ ]*' | sort -u | paste -sd, -; }
k_reads
[ "$(mt_of)" = 25 ] && ok || bad "R14 default curl max-time: [$(mt_of)] $(cat "$T/k.app")"
[ "$(pp_of)" = per_page=100 ] && ok || bad "R14 default per_page: [$(pp_of)] $(cat "$T/k.gh")"

# R15 the knobs: env override, clamp, non-integer fallback, and a settings row
# read through lib_env_apply (a fresh settings cache, the composed registry).
k_reads CI_ROLLOUT_CURL_MAX_TIME=40 CI_ROLLOUT_SEARCH_PER_PAGE=30
[ "$(mt_of)" = 40 ] && [ "$(pp_of)" = per_page=30 ] && ok || bad "R15 env override: [$(mt_of)] [$(pp_of)]"
k_reads CI_ROLLOUT_CURL_MAX_TIME=abc CI_ROLLOUT_SEARCH_PER_PAGE=500
[ "$(mt_of)" = 25 ] && [ "$(pp_of)" = per_page=100 ] && ok || bad "R15 abc -> 25, 500 -> 100: [$(mt_of)] [$(pp_of)]"
k_reads CI_ROLLOUT_CURL_MAX_TIME=0 CI_ROLLOUT_SEARCH_PER_PAGE=0
[ "$(mt_of)" = 5 ] && [ "$(pp_of)" = per_page=1 ] && ok || bad "R15 0 -> clamped 5 and 1: [$(mt_of)] [$(pp_of)]"
REG="$T/lanes.json"
"$DIR/bin/lanes-build.sh" --root "$DIR" --to "$REG" >/dev/null 2>&1 || bad "R15 lanes-build.sh could not compose the registry"
jq -e '.libs[] | select(.id == "ci-image-rollout") | .knobs | map(.env) == ["CI_ROLLOUT_CURL_MAX_TIME","CI_ROLLOUT_SEARCH_PER_PAGE"]' "$REG" >/dev/null && ok \
  || bad "R15 the registry has no ci-image-rollout libs entry"
mkdir -p "$T/h/state"
jq -nc '{fetched_at:1700000000, values:{"lib.ci-image-rollout.ci_rollout_curl_max_time":"40","lib.ci-image-rollout.ci_rollout_search_per_page":"30"}, seeded:{}}' \
  > "$T/h/state/settings-cache.json"
k_reads LANE_REGISTRY="$REG" LANE_GATE_NOW=1700000010
[ "$(mt_of)" = 40 ] && [ "$(pp_of)" = per_page=30 ] && ok || bad "R15 settings rows: [$(mt_of)] [$(pp_of)]"
k_reads LANE_REGISTRY="$REG" LANE_GATE_NOW=1700000010 LANE_GATE_DISABLE=1
[ "$(mt_of)" = 25 ] && [ "$(pp_of)" = per_page=100 ] && ok || bad "R15 LANE_GATE_DISABLE=1 reads no row: [$(mt_of)] [$(pp_of)]"
scratch_rm "$T/h/state"

# R16 the re-run warning: only after an --apply that filed on a GitHub board
WARN='ci-image-rollout: GitHub search needs time to index new issues; wait before an --apply re-run, or it can file a duplicate (docs/CI-IMAGES.md)'
warned() { grep -qxF -- "$WARN" "$T/r.err"; }
reset_fx; yml Fixture_beta; put "$FX/search/Fixture_beta" "$EMPTY_SEARCH"; put "$FX/create/Fixture_beta" '{"number":101}'
roll file beta --apply; rc=$?
[ "$rc" = 0 ] && grep -qx 'filed beta Fixture/beta#101' "$T/r.out" && warned && ok || bad "R16 a GitHub filing warns: rc=$rc err=$(cat "$T/r.err")"
grep -qF 'GitHub search' "$T/r.out" && bad "R16 the warning must go to stderr" || ok
roll file beta; rc=$?
[ "$rc" = 0 ] && ! warned && ok || bad "R16 a dry run does not warn: rc=$rc err=$(cat "$T/r.err")"
put "$FX/create/Fixture_beta" '{"message":"Validation Failed"}' 1
roll file beta --apply; rc=$?
[ "$rc" = 1 ] && ! warned && ok || bad "R16 a failed create does not warn: rc=$rc err=$(cat "$T/r.err")"
jq -n '{total_count:1, incomplete_results:false, items:[{number:41, body:"x\nci-image-rollout-of: BH-7256 repo=Fixture/beta"}]}' > "$FX/search/Fixture_beta"
roll file beta --apply; rc=$?
[ "$rc" = 0 ] && grep -q '^already-filed beta' "$T/r.out" && ! warned && ok || bad "R16 already filed does not warn: rc=$rc out=$(cat "$T/r.out")"
reset_fx; yml Fixture_alpha-os
http GET "$APPB/boards" '{"boards":[{"id":"b1"}]}'; http GET "$APPB/boards/b1/tickets" '[]'
http POST "$APPB/boards/b1/tickets" '{"ticket":{"id":"t9","key":"AL-9"}}' 201
roll file alpha-os --apply; rc=$?
[ "$rc" = 0 ] && grep -qx 'filed alpha-os AL-9' "$T/r.out" && ! warned && ok || bad "R16 an app-board filing does not warn: rc=$rc err=$(cat "$T/r.err")"

# R17 the child body carries the MonkCI caveat and names project-6's pattern
roll body beta; rc=$?
step5=$(grep '^5\. ' "$T/r.out")
[ "$rc" = 0 ] && grep -qF 'example-org/project-6 `.github/actions/ci-image/action.yml`' <<<"$step5" && grep -qF 'MonkCI' <<<"$step5" && ok \
  || bad "R17 step 5 of the body names project-6's host-run pattern: rc=$rc [$step5]"
has "$KIT/ci-image-job.yml" '.github/actions/ci-image' && ok || bad "R17 the job header names project-6's host-run pattern"

# R18 the on-image decision table, through `plan <project>`. on-image comes
# only from a 200 answer: a workflow file named exactly ci-image.y(a)ml, or a
# ci/ci-image.conf file. A repo on the image gets no dedup read.
reset_fx; put "$FX/search/Fixture_beta" "$EMPTY_SEARCH"
wf() { put "$FX/contents/Fixture_beta" "$1"; }
conf_calls() { grep -c 'contents/ci/ci-image.conf' "$FX/calls"; }
search_calls() { grep -c 'search/issues' "$FX/calls"; }
wf '[{"name":"ci.yml","type":"file"},{"name":"ci-image.yml","type":"file"}]'
[ "$(verdict beta)" = on-image ] && [ "$(search_calls)" = 0 ] && [ "$(conf_calls)" = 0 ] && ok || bad "R18 ci.yml + ci-image.yml = on-image: $(cat "$T/r.out") calls=$(cat "$FX/calls")"
roll plan beta; [ "$?" = 0 ] && ok || bad "R18 on-image is rc 0"
wf '[{"name":"test.yaml","type":"file"},{"name":"ci-image.yaml","type":"file"}]'
[ "$(verdict beta)" = on-image ] && [ "$(search_calls)" = 0 ] && ok || bad "R18 test.yaml + ci-image.yaml = on-image: $(cat "$T/r.out")"
wf '[{"name":"ci.yml","type":"file"}]'
put "$FX/conf/Fixture_beta" '{"name":"ci-image.conf","path":"ci/ci-image.conf","type":"file","content":"aW1hZ2U9Cg=="}'
[ "$(verdict beta)" = on-image ] && [ "$(search_calls)" = 0 ] && [ "$(conf_calls)" = 1 ] && ok || bad "R18 ci.yml + conf = on-image: $(cat "$T/r.out") calls=$(cat "$FX/calls")"
scratch_rm "$FX/conf"
[ "$(verdict beta)" = runs-ci ] && [ "$(conf_calls)" = 1 ] && [ "$(search_calls)" = 1 ] && ok || bad "R18 ci.yml + conf 404 = runs-ci: $(cat "$T/r.out") calls=$(cat "$FX/calls")"
wf '[{"name":"ci-image.yml.disabled","type":"file"},{"name":"ci.yml","type":"file"}]'
[ "$(verdict beta)" = runs-ci ] && ok || bad "R18 ci-image.yml.disabled is not on-image: $(cat "$T/r.out")"
wf '[{"name":"my-ci-image.yml","type":"file"},{"name":"ci.yml","type":"file"}]'
[ "$(verdict beta)" = runs-ci ] && ok || bad "R18 my-ci-image.yml is not on-image: $(cat "$T/r.out")"
wf '[{"name":"ci-image.yml","type":"dir"},{"name":"ci.yml","type":"file"}]'
[ "$(verdict beta)" = runs-ci ] && ok || bad "R18 a ci-image.yml directory is not on-image: $(cat "$T/r.out")"
wf '[{"name":"ci.yml","type":"file"}]'
put "$FX/conf/Fixture_beta" '' 75 'gh: rate limited'
v=$(verdict beta); roll plan beta; rc=$?
[ "$v" = "unknown rate-limited" ] && [ "$rc" = 1 ] && [ "$(search_calls)" = 0 ] && ok || bad "R18 conf rc 75 = unknown rate-limited rc 1: [$v] rc=$rc"
put "$FX/conf/Fixture_beta" '{"message":"Forbidden"}' 1 'gh: Forbidden (HTTP 403)'
[ "$(verdict beta)" = "unknown conf-read-failed" ] && [ "$(search_calls)" = 0 ] && ok || bad "R18 conf 403 = unknown conf-read-failed: $(cat "$T/r.out")"
put "$FX/conf/Fixture_beta" '' 0
[ "$(verdict beta)" = "unknown conf-read-failed" ] && ok || bad "R18 conf rc 0 with an empty answer = unknown: $(cat "$T/r.out")"
put "$FX/conf/Fixture_beta" '[{"name":"x","type":"file"}]'
[ "$(verdict beta)" = "unknown conf-read-failed" ] && ok || bad "R18 conf answer that is not a file = unknown: $(cat "$T/r.out")"
wf '[{"name":"README.md","type":"file"}]'
[ "$(verdict beta)" = no-ci ] && [ "$(conf_calls)" = 0 ] && [ "$(search_calls)" = 0 ] && ok || bad "R18 README.md = no-ci with no conf read: $(cat "$T/r.out") calls=$(cat "$FX/calls")"
# An app-board repo on the image: no board context, no ticket list read.
reset_fx; put "$FX/contents/Fixture_alpha-os" '[{"name":"ci-image.yml","type":"file"},{"name":"ci.yml","type":"file"}]'
roll file alpha-os --apply; rc=$?
[ "$rc" = 0 ] && grep -qx 'on-image alpha-os Fixture/alpha-os' "$T/r.out" && ! grep -q '^curl ' "$FX/calls" && [ ! -s "$FX/creates" ] && ok \
  || bad "R18 app-board on-image: rc=$rc out=$(cat "$T/r.out") calls=$(cat "$FX/calls")"

echo "ci-image-rollout.bh-7256: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
