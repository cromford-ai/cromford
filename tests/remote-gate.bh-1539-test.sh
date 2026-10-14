#!/bin/bash
# tests/remote-gate.bh-1539-test.sh — the five BH-1527 review follow-ups on
# bin/remote-gate.sh's composed job (BH-1539).
#
# Two of these pin behaviour that already works and was only ever checked by
# hand (the exit-125 merge-base mismatch guard, and the BLIND rule NOT firing on
# a "no merge base" phrase mid-line). Three are defects:
#   - a tracked file under a NESTED excluded directory (tests/fixtures/x/.claude/)
#     came back as deleted on the host, because the restore named top-level
#     pathspecs only, so a clean tree grew a synthetic commit and the file showed
#     up in the three-dot diff;
#   - the host line printed the synthetic snapshot commit as `HEAD`, so a report
#     cited a sha that exists nowhere but that host;
#   - `--` command mode merged the command's stderr into stdout (`2>&1 | tee`),
#     so a caller capturing stdout got both streams.
#
# Everything runs through the REAL composed job: the ssh shim captures it, the
# rsync shim copies the upload into a fixture "host" tree (excluding by basename
# at any depth, as real rsync does), and the job executes there. Nothing here
# talks to Fly.
#
# Run from anywhere: tests/remote-gate.bh-1539-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
GATE="$DIR/bin/remote-gate.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
[ -f "$GATE" ] || { echo "FAIL: bin/remote-gate.sh does not exist"; exit 1; }

FIX="$T/fix"; mkdir -p "$FIX" "$T/fakebin" "$T/h/flags" "$T/h/logs" "$T/home"
: > "$T/h/flags/lane-off-testhost-tick"
JOBPATH="$(dirname "$(command -v git)"):/usr/bin:/bin:/usr/sbin:/sbin"
export GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.invalid
export GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.invalid
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$T/home/.gitconfig"
git config --global init.defaultBranch main
git config --global advice.detachedHead false

# ── the shims ────────────────────────────────────────────────────────────────
cat > "$T/fakebin/flyctl" <<'STUB'
#!/bin/bash
echo "$*" >> "$FIX/fly-calls"
case "$1 ${2:-}" in
  "proxy "*|"proxy") : > "$FIX/proxy-up"; exit 0 ;;
  "ssh issue") shift 3; printf 'k\n' > "$1"; printf 'c\n' > "$1-cert.pub"; exit 0 ;;
esac
exit 0
STUB
cat > "$T/fakebin/nc" <<'STUB'
#!/bin/bash
[ -f "$FIX/proxy-up" ] && exit 0
exit 1
STUB
# rsync's --exclude <name> matches that name at ANY depth; tar's --exclude does
# the same, which is why the shim uses the bare names. That is the whole point
# of the nested-exclude case below: the upload really does drop
# tests/fixtures/x/.claude/ and the job has to put it back from HEAD.
cat > "$T/fakebin/rsync" <<'STUB'
#!/bin/bash
src="${*: -2:1}"; dst="${*: -1}"; dst="$FIX/host${dst#root@localhost:}"
echo "$dst" >> "$FIX/uploads"
mkdir -p "$dst" || exit 23
case "$src" in
  *ctx.git/) ( cd "$src" && tar cf - . ) | ( cd "$dst" && tar xf - ) || exit 23 ;;
  *) ( cd "$src" && tar cf - --exclude .git --exclude node_modules --exclude .claude \
         --exclude .codegraph . ) | ( cd "$dst" && tar xf - ) || exit 23 ;;
esac
STUB
cat > "$T/fakebin/ssh" <<'STUB'
#!/bin/bash
case "$*" in *"bash -s"*) cat > "$FIX/job"; exit 0 ;; esac
exit 0
STUB
printf '#!/bin/bash\necho "        Valid: from 2026-01-01T00:00:00 to 2099-01-01T00:00:00"\n' > "$T/fakebin/ssh-keygen"
chmod +x "$T/fakebin"/*
export FIX

# gate <args...> — compose (and "send") a job; GOUT/GRC are the client's output.
gate() {
  rm -f "$FIX/job" "$FIX/uploads"
  GOUT=$(env PATH="$T/fakebin:$PATH" HOME="$T/home" HARNESS="$T/h" \
    TESTHOST_APP=fixture TESTHOST_PORT=10022 TESTHOST_ORG=fixture-org \
    TESTHOST_KEY="$T/key" REMOTE_GATE_PROXY_WAIT_S=2 bash "$GATE" "$@" 2>&1); GRC=$?
}
run_root() { local r; r=$(head -1 "$FIX/uploads" 2>/dev/null); r="${r%/base/}"; echo "${r%/base}"; }
# host — run the captured job against the uploaded tree; JOUT/JRC (both streams).
host() {
  local root; root=$(run_root)
  JOUT=$(cd / && env -i PATH="$JOBPATH" HOME="$T/home" GIT_CONFIG_GLOBAL="$T/home/.gitconfig" \
    GIT_CONFIG_NOSYSTEM=1 RG_RUN_DIR="$root" bash "$FIX/job" 2>&1); JRC=$?
}
# host_split — the same job with stdout and stderr captured SEPARATELY, into
# $T/out and $T/err. This is the only way to see which stream a line came out on.
host_split() {
  local root; root=$(run_root)
  ( cd / && env -i PATH="$JOBPATH" HOME="$T/home" GIT_CONFIG_GLOBAL="$T/home/.gitconfig" \
      GIT_CONFIG_NOSYSTEM=1 RG_RUN_DIR="$root" bash "$FIX/job" ) > "$T/out" 2> "$T/err"
  JRC=$?; JOUT=$(cat "$T/out" "$T/err")
}

# ── the fixture repo ─────────────────────────────────────────────────────────
S="$T/seed"; mkdir -p "$S/bin" "$S/tests" "$S/tests/fixtures/x/.claude" "$S/my.claude-thing"
printf '#!/bin/bash\n# bin/thing.sh\n' > "$S/bin/thing.sh"
# Tracked, and dropped by the upload's exclude at a NESTED path. The sibling
# my.claude-thing/ is tracked too and must NOT be treated as an exclude: the
# restore anchors on a whole path segment.
echo "tracked, excluded from the upload at a nested path" > "$S/tests/fixtures/x/.claude/nested.md"
echo "tracked, and NOT an excluded directory" > "$S/my.claude-thing/keep.md"
# probe.sh — what the host sees of its own git context.
cat > "$S/tests/probe.sh" <<'PROBE'
#!/bin/bash
git merge-base HEAD origin/main || echo "note: no merge base"
echo "--- three-dot ---"
git diff --name-only origin/main...HEAD | sort
echo "--- porcelain ---"
git status --porcelain
echo "--- log ---"
git log --oneline -1 --format=%s
PROBE
# midline.sh — the phrase "no merge base" NOT at line start. The BLIND rule must
# not fire on it: a suite reporting its OWN assertion text is not a blind suite.
cat > "$S/tests/midline.sh" <<'MID'
#!/bin/bash
echo "FAIL: expected no merge base"
echo "#3 b: no merge base with origin/main"
exit 0
MID
# twostream.sh — one line on each stream.
printf '#!/bin/bash\necho OUT\necho ERR >&2\nexit 0\n' > "$S/tests/twostream.sh"
# errblind.sh — blind, but only on stderr. Splitting the streams must not let
# this through: the rule scanned it when stderr was merged into stdout.
printf '#!/bin/bash\necho "no merge base — the untouched-files assertion did not run" >&2\nexit 0\n' > "$S/tests/errblind.sh"
git -C "$S" init -q && git -C "$S" add -A && git -C "$S" commit -qm seed
git clone -q --bare "$S" "$T/origin.git"

W="$T/w"
git clone -q "$T/origin.git" "$W" && git -C "$W" checkout -q -b feat
echo "# feat" >> "$W/bin/thing.sh"
git -C "$W" add -A && git -C "$W" commit -qm feat && git -C "$W" push -q origin feat
# main moves on, so the merge base is not main's tip (the shape the guard cares
# about). The move lands in the fixture origin by a fetch INTO the bare repo, not
# a push to main: this box's iron-law guard blocks `git push … main` outright,
# fixture or not, and a fixture that needs that verb does not run here.
M="$T/mainmove"; git clone -q "$T/origin.git" "$M"
echo "main moved" >> "$M/README.md"
git -C "$M" add -A && git -C "$M" commit -qm "main moves" \
  && git -C "$T/origin.git" fetch -q "$M" HEAD:refs/heads/main
git -C "$W" fetch -q origin
REAL=$(git -C "$W" rev-parse HEAD)
CIMB=$(git -C "$W" merge-base HEAD origin/main)

# ── 1. the exit-125 merge-base mismatch guard (pinned; hand-checked before) ──
# A context that does not reproduce the client's merge base is a RUNNER failure:
# nothing runs, the run root goes, and the rc is 125 — never a suite count.
forge() { # forge <update-ref args...> — rewrite the uploaded context's base ref
  local root; root=$(run_root)
  git -C "$root/ctx.git" update-ref "$@"
}
gate "$W" tests/probe.sh
forge refs/remotes/origin/main refs/rg/head
host
[ "$JRC" = 125 ] && ok || bad "1a a forged origin/main in the uploaded context did not exit 125 (exit $JRC): $JOUT"
case "$JOUT" in *"the host's merge base is"*"$CIMB"*) ok ;; *) bad "1a the 125 did not name both merge bases: $JOUT" ;; esac
case "$JOUT" in *"PASS "*|*"FAIL "*|*"suites,"*) bad "1a a suite ran (or was reported) after the context check failed: $JOUT" ;; *) ok ;; esac
[ -d "$(run_root)" ] && bad "1a the run root survived a 125 on the host: $(run_root)" || ok
gate "$W" tests/probe.sh
forge -d refs/remotes/origin/main
host
[ "$JRC" = 125 ] && ok || bad "1b a deleted origin/main in the uploaded context did not exit 125 (exit $JRC): $JOUT"
case "$JOUT" in *"merge base is 'none'"*) ok ;; *) bad "1b the 125 did not say the host had no merge base at all: $JOUT" ;; esac
gate "$W" -- bash tests/probe.sh
forge refs/remotes/origin/main refs/rg/head
host
[ "$JRC" = 125 ] && ok || bad "1c -- mode ran the command over a context that did not match (exit $JRC): $JOUT"

# ── 2. the BLIND rule does not fire mid-line (negative control) ──────────────
gate "$W" tests/midline.sh; host
[ "$JRC" = 0 ] && ok || bad "2a a suite printing 'no merge base' mid-line was failed as BLIND (exit $JRC): $JOUT"
case "$JOUT" in *"1 suites, 0 failing"*) ok ;; *) bad "2a the mid-line suite was not counted as a clean pass: $JOUT" ;; esac
gate "$W" -- bash tests/midline.sh; host
[ "$JRC" = 0 ] && ok || bad "2b -- mode failed a command printing 'no merge base' mid-line (exit $JRC): $JOUT"
case "$JOUT" in *BLIND*) bad "2b the BLIND rule fired on a mid-line phrase: $JOUT" ;; *) ok ;; esac

# ── 3. the host line names the REAL head, and labels the synthetic commit ────
hostline() { grep -m1 'host git context' <<<"$JOUT"; }
gate --full "$W" tests/probe.sh; host
HL=$(hostline)
case "$HL" in *"HEAD $REAL"*) ok ;; *) bad "3a the host line did not name the client's HEAD ($REAL): $HL" ;; esac
case "$HL" in *"(+ uncommitted"*) bad "3a a clean tree was reported as carrying uncommitted work: $HL" ;; *) ok ;; esac
echo "# dirty" >> "$W/bin/thing.sh"
gate --full "$W" tests/probe.sh; host
HL=$(hostline)
SYNTH=$(printf '%s\n' "$HL" | sed -n 's/.*uncommitted work as \([0-9a-f]\{40\}\).*/\1/p')
case "$HL" in
  *"HEAD $REAL (+ uncommitted work as "*) ok ;;
  *) bad "3b a dirty tree's host line did not label the synthetic commit (real $REAL): $HL" ;;
esac
{ [ -n "$SYNTH" ] && [ "$SYNTH" != "$REAL" ]; } && ok \
  || bad "3b the labelled synthetic sha is missing or equals the real HEAD (synth '$SYNTH', real $REAL): $HL"
case "$JOUT" in *"bin/thing.sh"*) ok ;; *) bad "3b the uncommitted edit did not reach the host's diff: $JOUT" ;; esac
git -C "$W" checkout -q -- bin/thing.sh

# ── 4. a tracked file under a NESTED excluded directory comes back from HEAD ──
gate --full "$W" tests/probe.sh; host
case "$JOUT" in
  *"tests/fixtures/x/.claude/nested.md"*) bad "4 a tracked file under a nested .claude/ read as a change on the host: $JOUT" ;;
  *) ok ;;
esac
case "$JOUT" in
  *"the uncommitted work in the upload"*) bad "4 a clean tree grew a synthetic commit on the host: $JOUT" ;;
  *) ok ;;
esac
case "$JOUT" in *"my.claude-thing/keep.md"*) bad "4 a directory merely NAMED like an exclude was dropped: $JOUT" ;; *) ok ;; esac
HL=$(hostline)
case "$HL" in *"HEAD $REAL"*) ok ;; *) bad "4 the clean host tree is not on the client's HEAD ($REAL): $HL" ;; esac

# ── 5. -- mode keeps the command's stderr on stderr ──────────────────────────
gate "$W" -- bash tests/twostream.sh; host_split
[ "$JRC" = 0 ] && ok || bad "5a the twostream command did not exit 0 through the job (exit $JRC): $JOUT"
grep -q '^OUT$' "$T/out" && ok || bad "5a the command's stdout line is not on the job's stdout: $(cat "$T/out")"
grep -q '^ERR$' "$T/out" && bad "5a the command's stderr leaked into the job's stdout: $(cat "$T/out")" || ok
grep -q '^ERR$' "$T/err" && ok || bad "5a the command's stderr line is not on the job's stderr: $(cat "$T/err")"
gate "$W" -- bash tests/errblind.sh; host
[ "$JRC" != 0 ] && ok || bad "5b a command printing 'no merge base' on stderr only passed the run (exit $JRC): $JOUT"
case "$JOUT" in *BLIND*) ok ;; *) bad "5b the run did not say why it failed a green command: $JOUT" ;; esac

echo "remote-gate bh-1539: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
