#!/bin/bash
# tests/publish-target-guard.bh-4083-test.sh — which repos bin/publish-share.sh
# will force-push to, and the workflow that arms the public one (BH-4083).
#
# The publisher ends in `git push --force`, so its --repo guard is what stands
# between a typo and an overwritten repository. One rule applies: the name must
# be an EXACT line of catalog/share-publish-targets.conf. BH-4083 added the conf
# for the public copy (cromford-ai/cromford); BH-4834 retired the old path where
# a name ending in "-share" passed on the suffix alone.
#
# G*  drive the real script, copied into a scratch repo next to a conf file this
#     suite writes, so each case controls the allowlist. A refusal must be rc 2
#     with "refusing to publish" and must happen before the clone (the clone
#     prints "upstream HEAD = …"). A pass must reach that line.
# C*  the committed allowlist itself.
# W*  .github/workflows/publish-cromford.yml: with no CROMFORD_DEPLOY_KEY its
#     gate step says "not configured" and exits 0, and every later step is
#     conditional on that gate, so nothing installs, builds or pushes.
#
# Run from anywhere: tests/publish-target-guard.bh-4083-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0; SKIP=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
PUBLISHER="$DIR/bin/publish-share.sh"
CONF="$DIR/catalog/share-publish-targets.conf"
WF="$DIR/.github/workflows/publish-cromford.yml"

if [ ! -f "$PUBLISHER" ]; then
  echo "SKIP publish-target-guard: no bin/publish-share.sh in this copy (the mirror does not ship it)"
  exit 0
fi

unset SHARE_MIRROR_REPO
export GIT_CONFIG_GLOBAL="$T/gitconfig" GIT_CONFIG_NOSYSTEM=1 GH_TOKEN=dummy-not-used
mkdir -p "$T/stub"
# publish-share.sh insists on gh before it clones; nothing here reaches it.
printf '#!/bin/sh\nexit 0\n' > "$T/stub/gh"; chmod +x "$T/stub/gh"
export PATH="$T/stub:$PATH"

# mkrepo <conf content or the word ABSENT> [remote url] — a scratch checkout
# carrying the real publisher and the given allowlist. Prints its root.
mkrepo() {
  local r; r=$(mktemp -d "$T/repo.XXXXXX")
  mkdir -p "$r/bin" "$r/catalog"
  cp "$PUBLISHER" "$r/bin/publish-share.sh"
  [ "$1" = ABSENT ] || printf '%s' "$1" > "$r/catalog/share-publish-targets.conf"
  {
    git -C "$r" init -q -b main
    echo x > "$r/README.md"
    git -C "$r" add -A && git -C "$r" -c user.email=t@example.com -c user.name=t commit -qm init
    [ -z "${2:-}" ] || git -C "$r" remote add origin "$2"
  } >/dev/null 2>&1
  echo "$r"
}
run() { # <repo> <target> — prints rc, output in $T/last.out
  bash "$1/bin/publish-share.sh" --dry-run --repo "$2" --ref HEAD --out "$(mktemp -d "$T/out.XXXXXX")" > "$T/last.out" 2>&1
  echo $?
}
refused() { # <label> <repo> <target>
  local rc; rc=$(run "$2" "$3")
  if [ "$rc" = 2 ] && grep -q 'refusing to publish' "$T/last.out" && ! grep -q 'upstream HEAD =' "$T/last.out"; then ok
  else bad "$1: '$3' should be refused before the clone (rc=$rc): $(head -3 "$T/last.out" | tr '\n' ' ')"; fi
}
passed() { # <label> <repo> <target>
  run "$2" "$3" >/dev/null
  if grep -q 'upstream HEAD =' "$T/last.out" && ! grep -q 'refusing to publish' "$T/last.out"; then ok
  else bad "$1: '$3' should pass the guard and reach the clone: $(head -3 "$T/last.out" | tr '\n' ' ')"; fi
}

OLD="harness-share/cromford""-share"
STD=$'# header comment\ncromford-ai/cromford\n'
R1=$(mkrepo "$STD")
passed  "G1 allowlisted public target" "$R1" "cromford-ai/cromford"
refused "G2 a -share mirror is refused now (BH-4834)" "$R1" "$OLD"
refused "G3 a longer name"            "$R1" "cromford-ai/cromford-x"
refused "G4 the .git spelling"        "$R1" "cromford-ai/cromford.git"
refused "G5 the private upstream"     "$R1" "Fortu""nian/cromford"
refused "G6 trailing whitespace"      "$R1" "cromford-ai/Cromford "
refused "G7 a different case"         "$R1" "cromford-ai/Cromford"
refused "G8 the commented line"       "$R1" "# header comment"
refused "G9 no -share suffix"         "$R1" "harness-share/cromford"

# Only a comment and a blank line: nothing is listed.
R2=$(mkrepo $'# cromford-ai/cromford\n\n   \n')
refused "G10 a commented-out entry lists nothing" "$R2" "cromford-ai/cromford"
refused "G11 a commented line is not a name"      "$R2" "# cromford-ai/cromford"

# No allowlist at all: nothing is a target.
R3=$(mkrepo ABSENT)
refused "G12 conf missing" "$R3" "cromford-ai/cromford"
refused "G13 conf missing: nothing passes, -share included" "$R3" "$OLD"

# Allowlisted, but it is a remote of this checkout: still refused.
R4=$(mkrepo "$STD" "git@github.com:cromford-ai/cromford.git")
refused "G14 allowlisted but a remote of this checkout" "$R4" "cromford-ai/cromford"
grep -q 'remote' "$T/last.out" && ok || bad "G14 the refusal should name the remote: $(head -2 "$T/last.out" | tr '\n' ' ')"

# ── C. the committed allowlist ──────────────────────────────────────────────
if [ -f "$CONF" ]; then
  ACTIVE=$(grep -vE '^[[:space:]]*(#|$)' "$CONF")
  [ "$ACTIVE" = "cromford-ai/cromford" ] && ok \
    || bad "C1 catalog/share-publish-targets.conf must list exactly cromford-ai/cromford (got: $(tr '\n' '|' <<<"$ACTIVE"))"
  passed "C2 the committed allowlist admits the public target" "$(mkrepo "$(cat "$CONF")")" "cromford-ai/cromford"
else
  bad "C1 catalog/share-publish-targets.conf is missing"
fi

# ── W. the publish workflow ─────────────────────────────────────────────────
if [ ! -f "$WF" ]; then
  bad "W0 .github/workflows/publish-cromford.yml is missing"
elif ! python3 -c 'import yaml' 2>/dev/null; then
  SKIP=$((SKIP+1)); echo "SKIP W: python3 yaml is not installed"
else
  python3 - "$WF" "$T/wf" <<'PY' || bad "W0 could not parse $WF"
import os, sys, yaml
wf = yaml.safe_load(open(sys.argv[1]))
out = sys.argv[2]; os.makedirs(out, exist_ok=True)
on = wf.get(True, wf.get("on"))
open(out + "/meta", "w").write("\n".join([
    "concurrency=%s" % (wf.get("concurrency") or {}).get("group", ""),
    "push_main=%s" % ("main" in ((on or {}).get("push") or {}).get("branches", [])),
    "schedule=%s" % bool((on or {}).get("schedule")),
    "dispatch=%s" % ("workflow_dispatch" in (on or {})),
]) + "\n")
jobs = list(wf["jobs"].values())
assert len(jobs) == 1, "one job"
steps = jobs[0]["steps"]
gate = [i for i, s in enumerate(steps) if s.get("id") == "armed"]
assert len(gate) == 1, "one step with id: armed"
g = gate[0]
open(out + "/gate.sh", "w").write(steps[g]["run"])
open(out + "/gate.env", "w").write("\n".join(sorted((steps[g].get("env") or {}).keys())) + "\n")
with open(out + "/later", "w") as fh:
    for s in steps[g + 1:]:
        fh.write("%s\t%s\n" % (s.get("name", s.get("uses", "?")), s.get("if", "")))
with open(out + "/runs", "w") as fh:
    for s in steps:
        fh.write(s.get("run", "") + "\n")
for s in steps:
    if "install gitleaks" in s.get("name", "").lower():
        open(out + "/install.sh", "w").write(s["run"])
PY
  if [ -f "$T/wf/gate.sh" ]; then
    grep -qx 'concurrency=publish-cromford' "$T/wf/meta" && ok || bad "W1 concurrency group must be publish-cromford: $(cat "$T/wf/meta" | tr '\n' ' ')"
    # TEST-CHANGE BH-10006: the publish runs on a schedule and on dispatch, not
    # on every push to main (approved CI audit 2026-11-24). Its premise here is
    # unchanged: the public push runs only from main's own triggers.
    grep -qx 'push_main=False' "$T/wf/meta" && grep -qx 'schedule=True' "$T/wf/meta" && grep -qx 'dispatch=True' "$T/wf/meta" && ok \
      || bad "W2 triggers must be the schedule and workflow_dispatch, with no push: $(tr '\n' ' ' < "$T/wf/meta")"
    grep -qx 'CROMFORD_DEPLOY_KEY' "$T/wf/gate.env" && ok || bad "W3 the gate step must read CROMFORD_DEPLOY_KEY"
    # W4: no secret. The gate says so, exits 0, and records armed=false.
    : > "$T/wf/out-empty"
    CROMFORD_DEPLOY_KEY="" GITHUB_OUTPUT="$T/wf/out-empty" bash -e "$T/wf/gate.sh" > "$T/wf/gate-empty.out" 2>&1
    rc=$?
    if [ "$rc" = 0 ] && grep -qF 'CROMFORD_DEPLOY_KEY not set: not configured, nothing pushed' "$T/wf/gate-empty.out" \
       && grep -qx 'armed=false' "$T/wf/out-empty"; then ok
    else bad "W4 with no secret the gate must print 'not configured', exit 0 and set armed=false (rc=$rc, out=$(tr '\n' ' ' < "$T/wf/gate-empty.out"), output=$(tr '\n' ' ' < "$T/wf/out-empty"))"; fi
    # W5: with a secret, armed=true, and the secret is never echoed.
    : > "$T/wf/out-set"
    CROMFORD_DEPLOY_KEY="fixture-key-do-not-ship" GITHUB_OUTPUT="$T/wf/out-set" bash -e "$T/wf/gate.sh" > "$T/wf/gate-set.out" 2>&1
    rc=$?
    if [ "$rc" = 0 ] && grep -qx 'armed=true' "$T/wf/out-set" && ! grep -q 'fixture-key' "$T/wf/gate-set.out" "$T/wf/out-set"; then ok
    else bad "W5 with a secret the gate must set armed=true without echoing it (rc=$rc)"; fi
    # W6: every step after the gate runs only when armed.
    NLATER=$(grep -c . "$T/wf/later")
    NGATED=$(grep -cF "steps.armed.outputs.armed == 'true'" "$T/wf/later")
    if [ "$NLATER" -ge 2 ] && [ "$NLATER" = "$NGATED" ]; then ok
    else bad "W6 every step after the gate must carry if: steps.armed.outputs.armed == 'true' ($NGATED of $NLATER):"; cat "$T/wf/later"; fi
    # W7: the publish step aims at the allowlisted target, through the publisher.
    grep -qE 'bash bin/publish-share\.sh --repo cromford-ai/cromford --ref origin/main' "$T/wf/runs" && ok \
      || bad "W7 the workflow must run bin/publish-share.sh --repo cromford-ai/cromford --ref origin/main"
    # W8: the gitleaks pin is the one in bin/lib/gitleaks-pin.sh.
    PIN=$(bash -c '. "$1" && echo "$GITLEAKS_PIN_VERSION $GITLEAKS_PIN_SHA256"' _ "$DIR/bin/lib/gitleaks-pin.sh" 2>/dev/null)
    WPIN="$(sed -n 's/^V=\([0-9][0-9.]*\).*/\1/p' "$T/wf/install.sh" 2>/dev/null | head -1) $(sed -n 's/^SHA=\([0-9a-f]\{64\}\)$/\1/p' "$T/wf/install.sh" 2>/dev/null | head -1)"
    [ -n "$PIN" ] && [ "$PIN" = "$WPIN" ] && ok || bad "W8 the workflow's gitleaks pin '$WPIN' differs from bin/lib/gitleaks-pin.sh '$PIN'"
  fi
fi

# ── D. the workflow never reaches the mirror ────────────────────────────────
DROPPED=$(cd "$DIR/bin/share" && python3 -c 'import sanitize; print(sanitize.dropped(".github/workflows/publish-cromford.yml") or "")' 2>/dev/null)
[ -n "$DROPPED" ] && ok || bad "D1 sanitize.py must drop .github/workflows/publish-cromford.yml"

echo "publish-target-guard.bh-4083-test: $PASS pass, $FAIL fail, $SKIP skip"
[ "$FAIL" -eq 0 ]
