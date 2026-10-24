#!/bin/bash
# tests/test-impact-nightly-backstop.bh-8171-test.sh — BH-8171 (item 1 of
# #8050): THE NIGHTLY CORPUS STAYS THE BACKSTOP. `harness-nightly.yml` still
# runs every suite, even when HEAD carries a diff the PR rules narrow (the
# always cut BH-8098, the dir rows BH-8050 C0, the comment-only rule BH-8099).
#
#   N0  control: pull_request ci-select on the fixture diff selects < NTOT
#   N1  nightly ci-select selects all NTOT suites and names the full reason
#   N2  schedule ci-select selects all NTOT suites
#   N3  bin/ci-plan.sh --tier nightly-full plans all NTOT, mode=nightly-full
#   N4  nightly with TI_COMMENT_ONLY=1 still selects all NTOT
#   N5  the real harness-nightly.yml calls bin/ci-plan.sh --tier nightly-full
#
# The real bin/ci-plan.sh and bin/test-impact.sh drive N0-N4 over a scratch
# repo with fixed git dates. Self-contained: no network, no secrets, no clock.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok: $1"; }
bad() { FAIL=$((FAIL+1)); echo "not ok: $1"; }
command -v git >/dev/null || { echo "test-impact-nightly-backstop: git is required"; exit 2; }
export GIT_AUTHOR_DATE="@1790000000 +0000" GIT_COMMITTER_DATE="@1790000000 +0000"
export HARNESS="$T/empty"

# ── the scratch repository ──────────────────────────────────────────────────
R="$T/repo"
mkdir -p "$R/bin/lib" "$R/tests" "$R/catalog" "$R/docs"
for s in bin/ci-plan.sh bin/test-impact.sh; do
  scratch_install_closure "$s" "$R" > /dev/null || { echo "not ok: cannot install $s"; exit 1; }
done
cat > "$R/bin/lib/core.sh" <<'SH'
#!/bin/bash
# core lib header
core_alpha_fn() { echo alpha; }
SH
cat > "$R/bin/tool.sh" <<'SH'
#!/bin/bash
. "$(dirname "$0")/lib/core.sh"
core_alpha_fn
SH
printf '#!/bin/bash\necho other\n' > "$R/bin/other.sh"
printf '#!/bin/bash\necho third\n' > "$R/bin/third.sh"
printf '# x\nline one\n' > "$R/docs/x.md"
suite() { # <name> <body line>
  printf '#!/bin/bash\nDIR=$(cd "$(dirname "$0")/.." && pwd)\n%s\necho ok\n' "$2" > "$R/tests/$1-test.sh"
}
suite core   '. "$DIR/bin/lib/core.sh"; core_alpha_fn'
suite tool   'bash "$DIR/bin/tool.sh"'
suite other  'bash "$DIR/bin/other.sh"'
suite third  'bash "$DIR/bin/third.sh"'
suite plain1 'true'
suite plain2 'true'
suite always 'true'
printf 'tests/always-test.sh\n' > "$R/catalog/test-impact-always.txt"
gitc() { git -C "$R" -c user.email=t@example.com -c user.name=t "$@"; }
gitc init -q; gitc add -A; gitc commit -qm base
B0=$(git -C "$R" rev-parse HEAD)
# B1: a comment line of core.sh and a docs line, the shapes the PR rules narrow.
sed -i 's/^# core lib header$/# core lib header, reworded/' "$R/bin/lib/core.sh"
printf 'line two\n' >> "$R/docs/x.md"
gitc add -A; gitc commit -qm b1
NTOT=$(cd "$R" && ls tests/*.sh | grep -c .)

# cis <label> [env...] — ci-select over B0..HEAD; list in $T/<label>, reason in $T/<label>.err.
cis() {
  local label="$1"; shift
  (cd "$R" && env -u GITHUB_ACTIONS -u TI_PR_TITLE -u TI_PR_LABELS -u TI_PR_HEAD_REF TI_BASE="$B0" "$@" \
     bin/test-impact.sh ci-select --out "$T/$label" 2> "$T/$label.err"); RC=$?
  N=$(grep -c . "$T/$label" 2>/dev/null); N=${N:-0}
}
allin() { # every suite of the tree is in $T/<label>
  local s
  for s in $(cd "$R" && ls tests/*.sh); do grep -qxF "$s" "$T/$1" || return 1; done
}

# ── N0. control: the fixture diff narrows a pull request.
cis l0 TI_EVENT=pull_request
{ [ "$RC" = 0 ] && [ "$N" -gt 0 ] && [ "$N" -lt "$NTOT" ]; } \
  && ok "N0 pull_request selects $N of $NTOT (the fixture narrows)" \
  || bad "N0 pull_request selected $N of $NTOT rc=$RC: the fixture proves nothing [$(cat "$T/l0.err")]"

# ── N1. nightly: the whole corpus, with the full reason.
cis l1 TI_EVENT=nightly
{ [ "$RC" = 0 ] && [ "$N" = "$NTOT" ] && allin l1; } \
  && ok "N1 nightly selects all $NTOT suites" || bad "N1 nightly selected $N of $NTOT rc=$RC"
grep -qF "full: event 'nightly' is not a pull request" "$T/l1.err" \
  && ok "N1 nightly names the full reason" || bad "N1 reason [$(cat "$T/l1.err")]"

# ── N2. schedule, the cron event the workflow carries.
cis l2 TI_EVENT=schedule
{ [ "$RC" = 0 ] && [ "$N" = "$NTOT" ] && allin l2; } \
  && ok "N2 schedule selects all $NTOT suites" || bad "N2 schedule selected $N of $NTOT rc=$RC"

# ── N3. the workflow's own entry point. TI_BASE is set on purpose: with no
# base, ci-select answers full for a second reason and hides the event arm.
rm -f "$T/go" "$T/l3"
NOUT=$(cd "$R" && env -u GITHUB_ACTIONS TI_BASE="$B0" CI_EVENT=schedule CI_QUARANTINE= GITHUB_OUTPUT="$T/go" \
         bin/ci-plan.sh --tier nightly-full --out "$T/l3" 2>&1); NRC=$?
N3=$(grep -c . "$T/l3" 2>/dev/null); N3=${N3:-0}
{ [ "$NRC" = 0 ] && grep -qx 'mode=nightly-full' "$T/go" 2>/dev/null && [ "$N3" = "$NTOT" ] && allin l3; } \
  && ok "N3 ci-plan --tier nightly-full plans all $NTOT suites" \
  || bad "N3 rc=$NRC planned $N3 of $NTOT go=[$(tr '\n' ' ' < "$T/go" 2>/dev/null)] [$NOUT]"

# ── N4. the comment-only switch does not leak into nightly.
cis l4 TI_EVENT=nightly TI_COMMENT_ONLY=1
{ [ "$RC" = 0 ] && [ "$N" = "$NTOT" ] && allin l4; } \
  && ok "N4 nightly with TI_COMMENT_ONLY=1 selects all $NTOT" || bad "N4 selected $N of $NTOT rc=$RC"

# ── N5. the real nightly workflow wires the full tier, unfiltered.
WF="$DIR/.github/workflows/harness-nightly.yml"
if [ ! -f "$WF" ]; then
  bad "N5 $WF is missing"
else
  grep -qF 'bin/ci-plan.sh --tier nightly-full' "$WF" \
    && ok "N5 harness-nightly.yml calls bin/ci-plan.sh --tier nightly-full" \
    || bad "N5 harness-nightly.yml has no bin/ci-plan.sh --tier nightly-full line"
  if grep -F -- '--tier nightly-full' "$WF" | grep -Eq '\|[[:space:]]*(select|head|grep -v)'; then
    bad "N5 a --tier nightly-full line pipes through a filter"
  else
    ok "N5 no --tier nightly-full line pipes through a filter"
  fi
fi

echo "test-impact-nightly-backstop: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
