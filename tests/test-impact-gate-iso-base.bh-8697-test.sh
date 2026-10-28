#!/bin/bash
# tests/test-impact-gate-iso-base.bh-8697-test.sh — BH-8697: THE GATE'S
# SNAPSHOT CARRIES A BASE, SO A DELTA RATCHET CAN DIFF AGAINST IT.
#
# The isolated runner and the fresh-main pass both run suites in a snapshot of
# the tree. Until BH-8697 that snapshot was ONE commit with no origin/main, so
# every suite that sources tests/lib/ratchet-delta.sh found no base in rd_base
# and failed "never a skip" — BH-8682's claim 4 was red on that alone
# (tests/scratch-closure-lint.bh-4552: "no base to diff against in
# /tmp/impact-gate.*/iso/repo"). Now the snapshot is two commits, base then
# head, with refs/remotes/origin/main at the base (rp_snapshot_build's shape).
#
# tests/base-probe-test.sh is rd_base in miniature: no origin/main is a red
# "no base"; else it prints the base's tree and the three-dot diff.
#
#   B1  isolated: rc 0, origin/main is the fork's tree, the diff is the branch's
#   B2  isolated, main moved past the fork: the base is still the fork
#   B3  isolated, the head deletes a file: the diff lists it, the tree lacks it
#   B4  the probe in a one-commit repo with no origin/main is red "no base"
#   B5  a bad --base runs no suite (rc 2); a base git cannot archive is rc 125,
#       could-not-run, and no suite runs without a base
#   B6  fresh main on: origin/main is main's tip, the diff is the branch's only
#   B7  the local runner: unchanged, rc 0
#
# B1-B3 and B5b need real root and setpriv; elsewhere they print SKIP.
# The real gate, selector and suite runner in a committed scratch repo.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0 FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }
done_() { echo "test-impact-gate-iso-base: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ]; exit; }

command -v git > /dev/null 2>&1 || { echo "test-impact-gate-iso-base: SKIPPED — needs git"; done_; }
export GIT_AUTHOR_DATE='2026-10-01T00:00:00Z' GIT_COMMITTER_DATE='2026-10-01T00:00:00Z'
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

# ── the fixture repo ────────────────────────────────────────────────────────
R="$T/repo"
mkdir -p "$R"
for s in bin/test-impact-gate.sh bin/test-impact.sh bin/test-suite-run.sh; do
  scratch_install_closure "$s" "$R" > /dev/null || { echo "cannot install $s"; exit 1; }
done
mkdir -p "$R/bin/lib" "$R/tests/lib" "$R/catalog" "$R/docs"
printf '# scratch lib\n' > "$R/tests/lib/scratch.sh"
printf '#!/bin/bash\nwidget() { echo 1; }\n' > "$R/bin/lib/widget.sh"
printf '#!/bin/bash\necho gone\n' > "$R/bin/gone.sh"
echo note > "$R/docs/n.md"
# The probe: an always suite, so every run of the gate runs it.
cat > "$R/tests/base-probe-test.sh" <<'SH'
#!/bin/bash
# Pins bin/lib/widget.sh's diff against origin/main (rd_base in miniature).
git cat-file -e 'origin/main^{commit}' 2>/dev/null && mb=$(git merge-base HEAD origin/main 2>/dev/null) \
  || { echo "probe: no base to diff against in $PWD"; echo "probe: 0 passed, 1 failed"; exit 1; }
echo "probe base-tree=$(git rev-parse "$mb^{tree}")"
echo "probe diff=$(git diff --name-only "$mb" HEAD | paste -sd, -)"
gone=no; [ -e bin/gone.sh ] && gone=yes; echo "probe gone-present=$gone"
echo "probe: 1 passed, 0 failed"
SH
printf 'tests/base-probe-test.sh\n' > "$R/catalog/test-impact-always.txt"
chmod +x "$R"/tests/*.sh "$R"/bin/*.sh
G() { git -C "$R" -c user.email=t@t -c user.name=t "$@"; }
G init -q -b main && G add -A && G commit -qm A || { echo "cannot build the fixture"; exit 1; }
A=$(G rev-parse HEAD); A_TREE=$(G rev-parse "$A^{tree}")
G checkout -q -b head
printf '# touched\n' >> "$R/bin/lib/widget.sh"
G commit -qam H || exit 1
H=$(G rev-parse HEAD)
G checkout -q -b del
G rm -q bin/gone.sh && G commit -qm D || exit 1
DEL=$(G rev-parse HEAD)
G checkout -q main
echo note2 >> "$R/docs/n.md"
G commit -qam M || exit 1
M=$(G rev-parse HEAD); M_TREE=$(G rev-parse "$M^{tree}")
G update-ref refs/remotes/origin/main "$M"
G checkout -q head

export HARNESS="$T/empty" TEST_IMPACT_GATE_FAST="$T/fast.empty" TEST_IMPACT_DURATIONS_FILE="$T/dur.tsv"
export TEST_IMPACT_GATE_TIERS="$T/no-tiers.tsv" SUITE_REUSE=off
unset TEST_IMPACT_GATE_FRESH_MAIN SUITE_REUSE_RUN_KEY GITHUB_ACTIONS
: > "$T/fast.empty"

# gate <tag> [args...] — the real gate in $R; output $T/<tag>.out, rc GRC.
gate() {
  local tag="$1"; shift
  ( cd "$R" && bin/test-impact-gate.sh "$@" ) > "$T/$tag.out" 2>&1
  GRC=$?
}
outs()  { grep -qF -- "$2" "$T/$1.out"; }
probe() { grep -m1 "^probe $2=" "$T/$1.out" | sed "s/^probe $2=//"; }

ISO=0
if [ "$(id -u)" = 0 ] && command -v setpriv > /dev/null 2>&1 && id nobody > /dev/null 2>&1 \
   && setpriv --reuid="$(id -u nobody)" --regid="$(id -g nobody)" --clear-groups true > /dev/null 2>&1; then
  ISO=1
fi

# ── B1: isolated, a normal branch ───────────────────────────────────────────
if [ "$ISO" = 1 ]; then
  gate b1 --base "$A" --head "$H" --runner isolated --fresh-main off
  [ "$GRC" = 0 ] && outs b1 "selected suites via isolated: passed" \
    && grep -q '^impact-gate: done tests/base-probe-test.sh rc=0' "$T/b1.out" \
    && ok "B1 isolated: rc 0, the probe found a base" || bad "B1 rc=$GRC: $(tail -8 "$T/b1.out")"
  [ "$(probe b1 base-tree)" = "$A_TREE" ] && [ "$(probe b1 diff)" = "bin/lib/widget.sh" ] \
    && ok "B1 origin/main is the fork, the diff is the branch's" \
    || bad "B1 base-tree=$(probe b1 base-tree) (want $A_TREE) diff=$(probe b1 diff)"
else
  echo "SKIP: B1 (needs root and setpriv)"; ok "B1 skipped"
fi

# ── B2: isolated, main moved past the fork ──────────────────────────────────
if [ "$ISO" = 1 ]; then
  gate b2 --base main --head "$H" --runner isolated --fresh-main off
  [ "$GRC" = 0 ] && [ "$(probe b2 base-tree)" = "$A_TREE" ] && [ "$(probe b2 diff)" = "bin/lib/widget.sh" ] \
    && ok "B2 main moved: the base is the fork, not main's tip" \
    || bad "B2 rc=$GRC base-tree=$(probe b2 base-tree) diff=$(probe b2 diff)"
else
  echo "SKIP: B2 (needs root and setpriv)"; ok "B2 skipped"
fi

# ── B3: isolated, the head deletes a file ───────────────────────────────────
if [ "$ISO" = 1 ]; then
  gate b3 --base "$A" --head "$DEL" --runner isolated --fresh-main off
  [ "$GRC" = 0 ] && [ "$(probe b3 diff)" = "bin/gone.sh,bin/lib/widget.sh" ] && [ "$(probe b3 gone-present)" = no ] \
    && ok "B3 a deleted file is in the diff and gone from the tree" \
    || bad "B3 rc=$GRC diff=$(probe b3 diff) gone-present=$(probe b3 gone-present)"
else
  echo "SKIP: B3 (needs root and setpriv)"; ok "B3 skipped"
fi

# ── B4: the probe is a real check ───────────────────────────────────────────
O="$T/one"
mkdir -p "$O" && git -C "$R" archive "$H" | tar -x -C "$O" \
  && git -C "$O" init -q && git -C "$O" add -A && git -C "$O" -c user.email=t@t -c user.name=t commit -qm one
( cd "$O" && bash tests/base-probe-test.sh ) > "$T/b4.out" 2>&1; RC=$?
[ "$RC" = 1 ] && outs b4 "probe: no base to diff against" && ok "B4 no origin/main: the probe is red" \
  || bad "B4 rc=$RC: $(cat "$T/b4.out")"

# ── B5: no suite runs without a base ────────────────────────────────────────
gate b5a --base nosuch-ref --head "$H" --runner isolated --fresh-main off
[ "$GRC" != 0 ] && ! grep -q '^impact-gate: done ' "$T/b5a.out" \
  && ok "B5a a bad --base: rc $GRC, no suite ran" || bad "B5a rc=$GRC: $(tail -5 "$T/b5a.out")"
if [ "$ISO" = 1 ]; then
  # git that refuses to archive the fork commit: the base cannot be snapshotted.
  REAL_GIT=$(command -v git)
  mkdir -p "$T/stub"
  cat > "$T/stub/git" <<SH
#!/bin/bash
for a in "\$@"; do [ "\$a" = "$A" ] && [ "\${*#*archive}" != "\$*" ] && { echo "stub: no archive of $A" >&2; exit 1; }; done
exec "$REAL_GIT" "\$@"
SH
  chmod +x "$T/stub/git"
  ( cd "$R" && PATH="$T/stub:$PATH" bin/test-impact-gate.sh --base "$A" --head "$H" --runner isolated --fresh-main off ) \
    > "$T/b5b.out" 2>&1; GRC=$?
  [ "$GRC" = 125 ] && outs b5b "could not snapshot" && ! grep -q '^impact-gate: done ' "$T/b5b.out" \
    && ok "B5b a base that cannot be snapshotted is rc 125, no suite ran" \
    || bad "B5b rc=$GRC: $(tail -5 "$T/b5b.out")"
else
  echo "SKIP: B5b (needs root and setpriv)"; ok "B5b skipped"
fi

# ── B6: fresh main on ───────────────────────────────────────────────────────
gate b6 --base "$A" --head "$H" --runner local --fresh-main on --fresh-ref main
[ "$GRC" = 0 ] && outs b6 "fresh main ${M:0:12}" \
  && [ "$(probe b6 base-tree)" = "$M_TREE" ] && [ "$(probe b6 diff)" = "bin/lib/widget.sh" ] \
  && ok "B6 fresh: origin/main is main's tip, the diff is the branch's" \
  || bad "B6 rc=$GRC base-tree=$(probe b6 base-tree) (want $M_TREE) diff=$(probe b6 diff): $(grep 'fresh' "$T/b6.out" | tail -3)"

# ── B7: the local runner is unchanged ───────────────────────────────────────
gate b7 --base "$A" --head "$H" --runner local --fresh-main off
[ "$GRC" = 0 ] && outs b7 "selected suites via local: passed" && ok "B7 local runner: rc 0" \
  || bad "B7 rc=$GRC: $(tail -5 "$T/b7.out")"

done_
