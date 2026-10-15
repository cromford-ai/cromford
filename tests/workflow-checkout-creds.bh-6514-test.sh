#!/bin/bash
# tests/workflow-checkout-creds.bh-6514-test.sh — BH-6522 (BH-6514.1): no
# workflow keeps the job token in .git/config after its checkout.
#
# THE DEFECT THIS PINS. actions/checkout@v4 writes the job token into
# .git/config as http.https://github.com/.extraheader unless the step says
# `persist-credentials: false`. Every later step of the job, including steps
# that run PR code, could read it. Three git network reads used that persisted
# credential; each now gets the token another way.
#
#   W1  every actions/checkout step in .github/workflows/*.yml has
#       persist-credentials: false (YAML false), or a
#       `# needs the checkout token: <fetch>` comment directly above `- uses:`.
#       Scratch fixtures: the string 'false', true with no comment and a
#       non-adjacent comment each count "without".
#   W2  prequeue-gate `verdict` env PQ_GIT_TOKEN is the job token; no ${{ in run
#   W3  the verdict run text, token set: the pull-head fetch gets the header
#       through GIT_CONFIG_* env only; not in argv, .git/config or the gate's env;
#       the mask prints before ::stop-commands::
#   W4  no token: a plain fetch; token + a missing pull ref: could-not-run
#       why=fetch-failed
#   W5  harness-ci `schema.sql applies over main's`: the same, with
#       SCHEMA_GIT_TOKEN; a bad base is rc 1; no token is a plain fetch
#   W6  the plan step's CI_PLAN_MAIN_HEAD_CMD, run through the real
#       bin/ci-plan.sh push path with a fake gh
#   W7  the lint job runs bin/sql-ident-lint.sh right after the model-id lint,
#       and the lint is rc 0 on this tree
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/workflow-checkout-creds.bh-6514-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
has() { case "$2" in *"$1"*) return 0 ;; esac; return 1; }
finish() { echo "workflow-checkout-creds.bh-6514: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ]; exit; }

CI_WF="$DIR/.github/workflows/harness-ci.yml"
NIGHTLY_WF="$DIR/.github/workflows/harness-nightly.yml"
PQ_WF="$DIR/.github/workflows/prequeue-gate.yml"
PUB_WF="$DIR/.github/workflows/publish-cromford.yml"
LINT="$DIR/bin/sql-ident-lint.sh"
PLAN="$DIR/bin/ci-plan.sh"
for f in "$CI_WF" "$NIGHTLY_WF" "$PQ_WF" "$PUB_WF" "$LINT" "$PLAN"; do
  [ -f "$f" ] && ok || bad "setup: $f is missing"
done
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
if ! python3 -c 'import yaml' 2>/dev/null; then
  [ -n "${CI:-}" ] && { bad "PyYAML missing on a CI runner"; finish; }
  echo "workflow-checkout-creds.bh-6514: PyYAML missing — skipped on this dev machine"; exit 0
fi

# ── W1. the checkout audit
# audit <workflow files...> — prints `<n> checkout steps, <k> with
# persist-credentials: false, <m> without`, then `excepted: <e>`, then one
# `without: <file>:<line>` per bad step. rc 1 when the raw and parsed counts differ.
cat > "$T/audit.py" <<'PY'
import re, sys, yaml
RAW = re.compile(r'^(\s*)(- )?uses:\s*["\']?actions/checkout@')
EXC = re.compile(r'^\s*# needs the checkout token: \S')
n = k = e = 0; without = []; broken = []
for path in sys.argv[1:]:
    text = open(path).read()
    lines = text.splitlines()
    raw = [i for i, l in enumerate(lines) if RAW.match(l)]
    steps = [s for j in (yaml.safe_load(text).get("jobs") or {}).values()
             for s in (j.get("steps") or []) if str(s.get("uses", "")).startswith("actions/checkout@")]
    if len(raw) != len(steps):
        broken.append(f"{path}: {len(raw)} raw checkout lines, {len(steps)} parsed steps")
        continue
    for i, s in zip(raw, steps):
        n += 1
        dash = RAW.match(lines[i]).group(2) is not None
        if dash and i > 0 and EXC.match(lines[i - 1]):
            e += 1
        elif (s.get("with") or {}).get("persist-credentials", None) is False:
            k += 1
        else:
            without.append(f"{path}:{i + 1}")
print(f"{n} checkout steps, {k} with persist-credentials: false, {len(without)} without")
print(f"excepted: {e}")
for w in without: print("without: " + w)
for b in broken: print("broken: " + b)
sys.exit(1 if broken else 0)
PY
W1OUT=$(python3 "$T/audit.py" "$DIR"/.github/workflows/*.yml 2>&1); W1RC=$?
head -n1 <<<"$W1OUT"
[ "$W1RC" -eq 0 ] && ok || bad "W1: the audit could not pair raw and parsed checkout steps [$W1OUT]"
W1N=$(printf '%s\n' "$W1OUT" | sed -nE '1s/^([0-9]+) checkout steps.*/\1/p')
W1M=$(printf '%s\n' "$W1OUT" | sed -nE '1s/.*, ([0-9]+) without$/\1/p')
[ -n "$W1N" ] && [ "$W1N" -gt 0 ] && ok || bad "W1: no checkout step found [$W1OUT]"
[ "$W1M" = 0 ] && ok || bad "W1: every checkout step must carry persist-credentials: false [$W1OUT]"
grep -q '^excepted: ' <<<"$W1OUT" && echo "W1 $(grep '^excepted: ' <<<"$W1OUT") (# needs the checkout token:)"
# The adversarial negatives, on a scratch workflow.
mkdir -p "$T/w1"
cat > "$T/w1/neg.yml" <<'YML'
name: neg
on: push
jobs:
  a:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          persist-credentials: 'false'
      - uses: actions/checkout@v4
        with:
          persist-credentials: true
      # needs the checkout token: git fetch origin main

      - uses: actions/checkout@v4
        with:
          persist-credentials: true
      - uses: actions/checkout@v4
        with:
          persist-credentials: false
      # needs the checkout token: git fetch origin main
      - uses: actions/checkout@v4
        with:
          persist-credentials: true
YML
NEG=$(python3 "$T/audit.py" "$T/w1/neg.yml" 2>&1)
[ "$(head -n1 <<<"$NEG")" = "5 checkout steps, 1 with persist-credentials: false, 3 without" ] && ok \
  || bad "W1 neg: the string 'false', true with no comment and a non-adjacent comment each count without [$NEG]"
grep -qx 'excepted: 1' <<<"$NEG" && ok || bad "W1 neg: only the adjacent comment is an exception [$NEG]"

# ── Workflow facts, read once.
mkdir -p "$T/w"
python3 - "$PQ_WF" "$CI_WF" "$T/w" <<'PY' || bad "setup: the workflow facts could not be read"
import sys, yaml
pq = yaml.safe_load(open(sys.argv[1])); ci = yaml.safe_load(open(sys.argv[2])); out = sys.argv[3]
v = [s for s in pq["jobs"]["gate"]["steps"] if s.get("id") == "verdict"][0]
open(out + "/verdict.sh", "w").write(v["run"])
open(out + "/verdict.token", "w").write(str((v.get("env") or {}).get("PQ_GIT_TOKEN", "")))
s = [s for s in ci["jobs"]["worker-jobs"]["steps"] if str(s.get("name", "")).startswith("schema.sql applies over main's")]
if s:
    open(out + "/schema.sh", "w").write(s[0]["run"])
    open(out + "/schema.token", "w").write(str((s[0].get("env") or {}).get("SCHEMA_GIT_TOKEN", "")))
p = [s for s in ci["jobs"]["plan"]["steps"] if s.get("id") == "plan"][0]
open(out + "/plan.cmd", "w").write(str((p.get("env") or {}).get("CI_PLAN_MAIN_HEAD_CMD", "")))
names = [str(x.get("name", "")) for x in ci["jobs"]["lint"]["steps"]]
lines = []
for i, x in enumerate(ci["jobs"]["lint"]["steps"]):
    if x.get("name") == "SQL identifier marker lint (BH-6514)":
        lines.append(f"sql\t{i}\t{x.get('run', '')}\t{'if' in x}")
    if x.get("name") == "model-id literal lint (BH-1510)":
        lines.append(f"model\t{i}")
open(out + "/lint.tsv", "w").write("\n".join(lines) + "\n")
PY

# ── W2. the verdict step's token env
[ "$(cat "$T/w/verdict.token" 2>/dev/null)" = '${{ github.token }}' ] && ok \
  || bad "W2: verdict env PQ_GIT_TOKEN must be \${{ github.token }} (got '$(cat "$T/w/verdict.token" 2>/dev/null)')"
grep -q '\${{' "$T/w/verdict.sh" && bad "W2: no \${{ }} expression inside the verdict run text" || ok

# ── The scratch origin: main, and pull/41/head adding y.txt. The checkout's
# bin/test-impact-gate.sh and bin/worker-schema-upgrade.sh are stubs that
# record their env, so what is driven is the workflow's own run text.
REAL_GIT=$(command -v git)
O="$T/origin.git"; S="$T/seed"
git init -q --bare "$O"; git init -q "$S"
sg() { git -C "$S" -c user.email=t@example.com -c user.name=t "$@"; }
mkdir -p "$S/bin"
cat > "$S/bin/test-impact-gate.sh" <<'SH'
#!/bin/bash
env > "$STUB_ENV"
f=""; while [ $# -gt 0 ]; do [ "$1" = --failed ] && f="$2"; shift; done
[ -n "$f" ] && : > "$f"
exit 0
SH
cat > "$S/bin/worker-schema-upgrade.sh" <<'SH'
#!/bin/bash
env > "$STUB_ENV"
printf '%s\n' "$*" > "$STUB_ARGV"
SH
chmod +x "$S/bin/"*.sh
echo base > "$S/x.txt"; sg add -A; sg commit -qm main; MS=$(git -C "$S" rev-parse HEAD)
echo y > "$S/y.txt"; sg add -A; sg commit -qm head41; HOK=$(git -C "$S" rev-parse HEAD)
sg push -q "$O" "$MS:refs/heads/main" "$HOK:refs/pull/41/head"
# A git first on PATH: every argv to argv.log; for a fetch, the config env to cfg.log.
mkdir -p "$T/gitw"
cat > "$T/gitw/git" <<SH
#!/bin/bash
printf '%s\n' "\$*" >> "\$GITW_LOG/argv.log"
case " \$* " in *" fetch "*)
  printf 'count=%s key=%s value=%s\n' "\${GIT_CONFIG_COUNT-unset}" "\${GIT_CONFIG_KEY_0-}" "\${GIT_CONFIG_VALUE_0-}" >> "\$GITW_LOG/cfg.log" ;;
esac
exec "$REAL_GIT" "\$@"
SH
chmod +x "$T/gitw/git"
TOK=tok-fixture-1
B64=$(printf 'x-access-token:%s' "$TOK" | base64 -w0)
HDR="count=1 key=http.https://github.com/.extraheader value=AUTHORIZATION: basic $B64"

# dryv <case> <pr> [VAR=value ...] — the verdict run text in a fresh clone of main.
dryv() {
  local c="$1" pr="$2"; shift 2
  "$REAL_GIT" clone -q "file://$O" "$T/wd-$c" 2>/dev/null; "$REAL_GIT" -C "$T/wd-$c" checkout -q "$MS"
  mkdir -p "$T/rt-$c" "$T/log-$c"
  ( cd "$T/wd-$c" && env PATH="$T/gitw:$PATH" GITW_LOG="$T/log-$c" PQ_PR="$pr" PQ_HEAD="$HOK" PQ_MAIN="$MS" \
      PQ_SUITES_IN="" RUNNER_TEMP="$T/rt-$c" STUB_ENV="$T/gate-env-$c" "$@" \
      bash --noprofile --norc "$T/w/verdict.sh" ) > "$T/out-$c" 2>&1
}
verdict() { sed -n 's/^::notice title=prequeue-verdict:://p' "$T/out-$1" | tail -n1; }
leaks() { # leaks <file> — rc 0 when it holds the token or its base64
  grep -qF -e "$TOK" -e "$B64" "$1" 2>/dev/null
}

# ── W3. token set: the header rides the one fetch as config env
dryv tok 41 PQ_GIT_TOKEN="$TOK"
V=$(verdict tok)
has "green " "$V " && ok || bad "W3: a token fetch of a present pull ref must reach the gate (verdict '$V') [$(cat "$T/out-tok")]"
grep -qxF "$HDR" "$T/log-tok/cfg.log" 2>/dev/null && ok \
  || bad "W3: the pull-head fetch must get the extraheader through GIT_CONFIG_* [$(cat "$T/log-tok/cfg.log" 2>/dev/null)]"
leaks "$T/log-tok/argv.log" && bad "W3: the token or its header is in a git argv" || ok
[ -s "$T/log-tok/argv.log" ] && ok || bad "W3: the git wrapper saw no call (the argv check proves nothing)"
leaks "$T/wd-tok/.git/config" && bad "W3: the token reached .git/config" || ok
[ -s "$T/gate-env-tok" ] && ok || bad "W3: the stub gate did not run"
grep -q '^PQ_GIT_TOKEN=' "$T/gate-env-tok" 2>/dev/null && bad "W3: PQ_GIT_TOKEN reached the gate's env" || ok
grep -q '^GIT_CONFIG_' "$T/gate-env-tok" 2>/dev/null && bad "W3: GIT_CONFIG_* reached the gate's env" || ok
leaks "$T/gate-env-tok" && bad "W3: the token or its header reached the gate's env" || ok
MASK=$(grep -nxF "::add-mask::$B64" "$T/out-tok" | head -n1 | cut -d: -f1)
STOP=$(grep -n '^::stop-commands::' "$T/out-tok" | head -n1 | cut -d: -f1)
[ -n "$MASK" ] && [ -n "$STOP" ] && [ "$MASK" -lt "$STOP" ] && ok \
  || bad "W3: ::add-mask::<base64> must print before ::stop-commands:: (mask line '$MASK', stop line '$STOP')"
[ "$(grep -cF -e "$TOK" "$T/out-tok")" = 0 ] && ok || bad "W3: the raw token is in the step output"

# ── W4. no token: plain fetch; a missing pull ref: fetch-failed
dryv plain 41
V=$(verdict plain)
has "green " "$V " && ok || bad "W4: no token must fall back to a plain fetch and reach the gate (verdict '$V') [$(cat "$T/out-plain")]"
grep -qx 'count=unset key= value=' "$T/log-plain/cfg.log" 2>/dev/null && ok \
  || bad "W4: with no token the fetch must carry no GIT_CONFIG_* [$(cat "$T/log-plain/cfg.log" 2>/dev/null)]"
grep -q '::add-mask::' "$T/out-plain" && bad "W4: no token, no mask line" || ok
dryv miss 42 PQ_GIT_TOKEN="$TOK"
V=$(verdict miss)
{ has "could-not-run " "$V " && has "why=fetch-failed" "$V"; } && ok \
  || bad "W4: a token fetch of a missing pull ref is could-not-run why=fetch-failed (verdict '$V')"
[ ! -e "$T/gate-env-miss" ] && ok || bad "W4: a failed fetch must not run the gate"

# ── W5. the schema replay step
[ "$(cat "$T/w/schema.token" 2>/dev/null)" = '${{ github.token }}' ] && ok \
  || bad "W5: schema step env SCHEMA_GIT_TOKEN must be \${{ github.token }} (got '$(cat "$T/w/schema.token" 2>/dev/null)')"
# drys <case> <base> [VAR=value ...] — the run text under bash -e, as Actions runs it.
drys() {
  local c="$1" base="$2"; shift 2
  "$REAL_GIT" clone -q "file://$O" "$T/sd-$c" 2>/dev/null; "$REAL_GIT" -C "$T/sd-$c" checkout -q "$MS"
  mkdir -p "$T/slog-$c"
  ( cd "$T/sd-$c" && env PATH="$T/gitw:$PATH" GITW_LOG="$T/slog-$c" BASE="$base" GITHUB_EVENT_NAME=push \
      STUB_ENV="$T/upg-env-$c" STUB_ARGV="$T/upg-argv-$c" "$@" \
      bash --noprofile --norc -eo pipefail "$T/w/schema.sh" ) > "$T/sout-$c" 2>&1
  echo $?
}
if [ -s "$T/w/schema.sh" ]; then
  RC=$(drys tok "$MS" SCHEMA_GIT_TOKEN="$TOK")
  [ "$RC" = 0 ] && ok || bad "W5: a token fetch of a base on the origin is rc 0 (rc=$RC) [$(cat "$T/sout-tok")]"
  grep -qxF "$HDR" "$T/slog-tok/cfg.log" 2>/dev/null && ok \
    || bad "W5: the base fetch must get the extraheader through GIT_CONFIG_* [$(cat "$T/slog-tok/cfg.log" 2>/dev/null)]"
  [ "$(cat "$T/upg-argv-tok" 2>/dev/null)" = "--base FETCH_HEAD" ] && ok \
    || bad "W5: bin/worker-schema-upgrade.sh gets --base FETCH_HEAD (got '$(cat "$T/upg-argv-tok" 2>/dev/null)')"
  grep -q '^SCHEMA_GIT_TOKEN=' "$T/upg-env-tok" 2>/dev/null && bad "W5: SCHEMA_GIT_TOKEN reached worker-schema-upgrade.sh" || ok
  grep -q '^GIT_CONFIG_' "$T/upg-env-tok" 2>/dev/null && bad "W5: GIT_CONFIG_* reached worker-schema-upgrade.sh" || ok
  leaks "$T/upg-env-tok" && bad "W5: the token or its header reached worker-schema-upgrade.sh" || ok
  leaks "$T/slog-tok/argv.log" && bad "W5: the token or its header is in a git argv" || ok
  leaks "$T/sd-tok/.git/config" && bad "W5: the token reached .git/config" || ok
  grep -qxF "::add-mask::$B64" "$T/sout-tok" && ok || bad "W5: the header's base64 must be masked"
  RC=$(drys badbase 0123456789abcdef0123456789abcdef01234567 SCHEMA_GIT_TOKEN="$TOK")
  { [ "$RC" = 1 ] && grep -q 'could not fetch base' "$T/sout-badbase"; } && ok \
    || bad "W5: a base not on the origin is rc 1 'could not fetch base' (rc=$RC) [$(cat "$T/sout-badbase")]"
  [ ! -e "$T/upg-argv-badbase" ] && ok || bad "W5: a failed fetch must not run the upgrade"
  RC=$(drys plain "$MS")
  { [ "$RC" = 0 ] && grep -qx 'count=unset key= value=' "$T/slog-plain/cfg.log"; } && ok \
    || bad "W5: no token is a plain fetch, rc 0 (rc=$RC) [$(cat "$T/slog-plain/cfg.log" 2>/dev/null)]"
else
  bad "W5: no step 'schema.sql applies over main's' in jobs.worker-jobs"
fi

# ── W6. the plan step reads main's head through gh api
CMD=$(cat "$T/w/plan.cmd" 2>/dev/null)
[ "$CMD" = 'gh api repos/${{ github.repository }}/git/ref/heads/main --jq .object.sha' ] && ok \
  || bad "W6: plan env CI_PLAN_MAIN_HEAD_CMD (got '$CMD')"
mkdir -p "$T/ghbin"
cat > "$T/ghbin/gh" <<'SH'
#!/bin/bash
[ "$*" = "api repos/o/r/git/ref/heads/main --jq .object.sha" ] && { echo s9; exit 0; }
exit 1
SH
printf '#!/bin/bash\necho %s\n' "'{\"workflow_runs\":[]}'" > "$T/runs-gh"
cat > "$T/impact.sh" <<'SH'
#!/bin/bash
OUT=""; while [ $# -gt 0 ]; do [ "$1" = --out ] && OUT="$2"; shift; done
printf 'tests/s0001-test.sh\n' > "${OUT:-/dev/stdout}"
SH
chmod +x "$T/ghbin/gh" "$T/runs-gh" "$T/impact.sh"
# plan6 <case> <main-head cmd>
plan6() {
  : > "$T/go-$1"
  env PATH="$T/ghbin:$PATH" CI_EVENT=push CI_ACTOR='mergify[bot]' CI_PLAN_GH="$T/runs-gh" CI_REPO=o/r \
    CI_SHA=s0 CI_PLAN_SETTLE_S=0 CI_PLAN_MAIN_HEAD_CMD="$2" CI_PLAN_IMPACT="$T/impact.sh" \
    GITHUB_OUTPUT="$T/go-$1" GITHUB_STEP_SUMMARY="$T/sum-$1" "$PLAN" --out "$T/list-$1" > "$T/pout-$1" 2>&1
}
go6() { sed -n "s/^$2=//p" "$T/go-$1" | tail -n1; }
plan6 moved "${CMD//'${{ github.repository }}'/o/r}"
{ [ "$(go6 moved corpus)" = 0 ] && has "main has already moved to s9" "$(go6 moved summary)"; } && ok \
  || bad "W6: gh api answering s9 makes the push plan queue-tested (corpus=$(go6 moved corpus) summary='$(go6 moved summary)') [$(cat "$T/pout-moved")]"
plan6 unread "${CMD//'${{ github.repository }}'/o/x}"
[ "$(go6 unread corpus)" = 1 ] && [ "$(go6 unread mode)" = full ] && ok \
  || bad "W6: an unanswered main-head read runs the full corpus (corpus=$(go6 unread corpus) mode=$(go6 unread mode))"

# ── W7. the lint step
SQLI=$(awk -F'\t' '$1 == "sql" { print $2 }' "$T/w/lint.tsv")
MODI=$(awk -F'\t' '$1 == "model" { print $2 }' "$T/w/lint.tsv")
[ -n "$SQLI" ] && [ -n "$MODI" ] && [ "$SQLI" = $((MODI + 1)) ] && ok \
  || bad "W7: 'SQL identifier marker lint (BH-6514)' must follow 'model-id literal lint (BH-1510)' (at '$SQLI', model-id at '$MODI')"
[ "$(awk -F'\t' '$1 == "sql" { print $3 }' "$T/w/lint.tsv")" = "bin/sql-ident-lint.sh" ] && ok \
  || bad "W7: the step runs bin/sql-ident-lint.sh"
[ "$(awk -F'\t' '$1 == "sql" { print $4 }' "$T/w/lint.tsv")" = False ] && ok || bad "W7: the step has no if:"
LOUT=$("$LINT" 2>&1); LRC=$?
[ "$LRC" = 0 ] && ok || bad "W7: bin/sql-ident-lint.sh must be rc 0 on this tree (rc=$LRC) [$LOUT]"

finish
