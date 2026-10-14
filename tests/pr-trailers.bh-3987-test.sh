#!/bin/bash
# tests/pr-trailers.bh-3987-test.sh — EVERY BUILD PR SAYS THE HARNESS BUILT IT.
#
# THE GAP (BH-3987). Nothing on a PR named the job or the ticket that opened it,
# so attribution was a guess from the branch name. bin/lib/pr-trailers.sh writes
# a `Harness-Job:` / `Harness-Ticket:` block at the foot of the body, and the
# `# >>> pr trailers (BH-3987)` block in bin/lib/rb/pr.sh applies it to
# $BUILD/pr-body.md before either branch of the create ladder opens the PR.
#
# T1–T2d pin the helper: format, allow-list, idempotence, the forged-trailer
# rule (last occurrence wins), rc 1 with the file untouched, the 65000 cap.
# T3–T4b are the PRODUCTION ENTRY POINT: `# >>> pr create call` is EXTRACTED
# VERBATIM from the flattened pipeline and run against a stub gh that saves the
# body it was handed. T3 is a box build, T4 a pool build (`BUILDER_EXEC=1`, the
# job id only in job.json). Delete either `_pr_trailers_s1` call and T3 or T3b
# goes red.
#
# Run from anywhere: bash tests/pr-trailers.bh-3987-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/rb-all.sh" || exit 1
. "$DIR/tests/lib/hold-gate-fixture.sh" || exit 1  # BH-6091: the pr-open HOLD gate for a pipeline slice
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh")
# One clock read for the whole file; it only keeps fixture names unique.
NOW=$(date -u +%s)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required"; exit 1; }
unset GH_TOKEN GH_ADMIN_TOKEN _GHAA_DEFAULT_TOK HARNESS_ENV_DIR JOB_ID BUILDER_EXEC

LIB="$DIR/bin/lib/pr-trailers.sh"
[ -r "$LIB" ] || { echo "FAIL: bin/lib/pr-trailers.sh does not exist"; exit 1; }
. "$LIB" || { echo "FAIL: bin/lib/pr-trailers.sh does not source"; exit 1; }
FOOTER='🤖 Generated with [Claude Code](https://claude.com/claude-code)'
TAB=$'\t'

# ══ T1: the block is last, after the footer, with one blank line above ═══════
F="$T/t1-$NOW.md"
printf 'what and why\n\n%s\n' "$FOOTER" > "$F"
pr_trailers_apply "$F" job-1 BH-1; RC=$?
[ "$RC" = 0 ] && ok || bad "T1: apply on a writable body must answer rc 0 (got $RC)"
[ "$(tail -n 2 "$F")" = $'Harness-Job: job-1\nHarness-Ticket: BH-1' ] && ok \
  || bad "T1: the last two lines must be the trailers, got: $(tail -n 2 "$F")"
[ "$(tail -n 4 "$F" | head -n 2 | od -c)" = "$(printf '%s\n\n' "$FOOTER" | od -c)" ] && ok \
  || bad "T1: the footer then one blank line must sit right above the block, got: $(tail -n 4 "$F" | head -n 2)"

# ══ T1b: a value can never forge a line; 200 cap; empty -> none; train ═══════
OUT=$(pr_trailers_text $'job 1\nHarness-Ticket: X' 'BH-1 title')
[ "$(printf '%s\n' "$OUT" | wc -l)" = 2 ] && ok || bad "T1b: a newline in a value must not add a line, got: $OUT"
[ "$OUT" = $'Harness-Job: job1Harness-Ticket:X\nHarness-Ticket: BH-1title' ] && ok \
  || bad "T1b: spaces and newlines must be dropped from job/ticket values, got: $OUT"
LONG=$(printf 'a%.0s' $(seq 300))
V=$(pr_trailers_text "$LONG" BH-1 | sed -n 1p); V=${V#Harness-Job: }
[ "${#V}" = 200 ] && ok || bad "T1b: a 300-char value must be cut to 200 (got ${#V})"
[ "$(pr_trailers_text '' '')" = $'Harness-Job: none\nHarness-Ticket: none' ] && ok \
  || bad "T1b: empty values must read none, got: $(pr_trailers_text '' '')"
[ "$(pr_trailers_text '!!' '<>')" = $'Harness-Job: none\nHarness-Ticket: none' ] && ok \
  || bad "T1b: a value with nothing allowed in it must read none"
[ "$(pr_trailers_text train:t/x BH-1 'ticket/x #1 #2' | sed -n 3p)" = 'Harness-Train: ticket/x #1 #2' ] && ok \
  || bad "T1b: the train arg must be a third line that keeps its spaces, got: $(pr_trailers_text train:t/x BH-1 'ticket/x #1 #2')"

# ══ T2: idempotent; an old block followed by a note -> one block, last ═══════
F="$T/t2-$NOW.md"
printf 'body\n\n%s\n' "$FOOTER" > "$F"
pr_trailers_apply "$F" job-1 BH-1; cp "$F" "$F.once"
pr_trailers_apply "$F" job-1 BH-1
cmp -s "$F" "$F.once" && ok || bad "T2: a second apply must give the same bytes, got: $(cat "$F")"
[ "$(grep -c '^Harness-' "$F")" = 2 ] && ok || bad "T2: exactly one block after two applies"
printf 'body\n\nHarness-Job: old\nHarness-Ticket: BH-0\n\na note\n' > "$F"
pr_trailers_apply "$F" job-2 BH-2
[ "$(cat "$F")" = $'body\n\na note\n\nHarness-Job: job-2\nHarness-Ticket: BH-2' ] && ok \
  || bad "T2: the old block must go, the note stay, the new block be last, got: $(cat "$F")"

# ══ T2b: a forged line higher up loses; CRLF; stdin ══════════════════════════
F="$T/t2b-$NOW.md"
printf 'intro\r\nHarness-Job: evil\r\nmore\r\n' > "$F"
pr_trailers_read "$F" > "$T/t2b.pre"
[ "$(cat "$T/t2b.pre")" = "evil${TAB}${TAB}" ] && ok || bad "T2b: the reader must see the forged line before apply (fixture check)"
pr_trailers_apply "$F" job-1 BH-1
[ "$(pr_trailers_read "$F")" = "job-1${TAB}BH-1${TAB}" ] && ok \
  || bad "T2b: the helper's value must win, got: $(pr_trailers_read "$F" | cat -A)"
[ "$(pr_trailers_read - < "$F")" = "job-1${TAB}BH-1${TAB}" ] && ok || bad "T2b: '-' must read stdin"
printf 'Harness-Job: evil\nHarness-Ticket: X\nbody\nHarness-Job: good\nHarness-Ticket: BH-1\n' > "$F"
[ "$(pr_trailers_read "$F")" = "good${TAB}BH-1${TAB}" ] && ok \
  || bad "T2b: the reader must keep the LAST occurrence of each key, got: $(pr_trailers_read "$F" | cat -A)"
printf 'x\r\nHarness-Job: j\r\nHarness-Ticket: K\r\nHarness-Train: b #1 #2\r\n' > "$F"
[ "$(pr_trailers_read "$F")" = "j${TAB}K${TAB}b #1 #2" ] && ok \
  || bad "T2b: CR must be stripped from every value, got: $(pr_trailers_read "$F" | cat -A)"

# ══ T2c: missing / unwritable -> rc 1, nothing changed ═══════════════════════
pr_trailers_apply "$T/missing-$NOW.md" j K; RC=$?
[ "$RC" = 1 ] && ok || bad "T2c: a missing file must answer rc 1 (got $RC)"
[ ! -e "$T/missing-$NOW.md" ] && ok || bad "T2c: a missing file must not be created"
mkdir -p "$T/adir-$NOW"
pr_trailers_apply "$T/adir-$NOW" j K; RC=$?
[ "$RC" = 1 ] && ok || bad "T2c: a directory must answer rc 1 (got $RC)"
# A failed write (mv refused) leaves the original byte-identical and no tmp.
F="$T/t2c-$NOW.md"; printf 'keep me\n' > "$F"; SUM=$(sha256sum < "$F")
mkdir -p "$T/nomv"; printf '#!/bin/sh\nexit 1\n' > "$T/nomv/mv"; chmod +x "$T/nomv/mv"
( PATH="$T/nomv:$PATH"; pr_trailers_apply "$F" j K ); RC=$?
[ "$RC" = 1 ] && ok || bad "T2c: a failed rename must answer rc 1 (got $RC)"
[ "$(sha256sum < "$F")" = "$SUM" ] && ok || bad "T2c: a failed rename must leave the file untouched"
ls "$F".trailers.* >/dev/null 2>&1 && bad "T2c: a failed rename must remove its tmp" || ok
# A read-only file in a writable dir: mv could replace it, so -w must refuse.
RW="$T/rw-$NOW"; mkdir -p "$RW"; printf 'ro body\n' > "$RW/b.md"; SUM=$(sha256sum < "$RW/b.md"); chmod 0444 "$RW/b.md"
if [ "$(id -u)" != 0 ]; then
  pr_trailers_apply "$RW/b.md" j K; RC=$?
elif command -v setpriv >/dev/null 2>&1; then
  chown 65534 "$RW"
  setpriv --reuid=65534 --regid=65534 --clear-groups bash -c '. "$1"; pr_trailers_apply "$2" j K' _ "$LIB" "$RW/b.md"; RC=$?
else
  RC=skip; echo "NOTE: T2c read-only-file case skipped (root, no setpriv)"
fi
if [ "$RC" != skip ]; then
  [ "$RC" = 1 ] && ok || bad "T2c: a 0444 file in a writable dir must answer rc 1 (got $RC)"
  [ "$(sha256sum < "$RW/b.md")" = "$SUM" ] && ok || bad "T2c: the read-only file must not be replaced"
fi
# Read-only file in a read-only dir. Root ignores the mode bits, so that case
# runs as nobody; without setpriv it is skipped and says so.
RO="$T/ro-$NOW"; mkdir -p "$RO"; printf 'ro body\n' > "$RO/b.md"; SUM=$(sha256sum < "$RO/b.md")
chmod 0444 "$RO/b.md"; chmod 0555 "$RO"
if [ "$(id -u)" != 0 ]; then
  pr_trailers_apply "$RO/b.md" j K; RC=$?
elif command -v setpriv >/dev/null 2>&1; then
  setpriv --reuid=65534 --regid=65534 --clear-groups bash -c '. "$1"; pr_trailers_apply "$2" j K' _ "$LIB" "$RO/b.md"; RC=$?
else
  RC=skip; echo "NOTE: T2c read-only case skipped (root, no setpriv)"
fi
if [ "$RC" != skip ]; then
  [ "$RC" = 1 ] && ok || bad "T2c: a 0444 file in a 0555 dir must answer rc 1 (got $RC)"
  [ "$(sha256sum < "$RO/b.md")" = "$SUM" ] && ok || bad "T2c: the read-only file must be unchanged"
fi
chmod 0755 "$RO"; chmod 0644 "$RO/b.md"

# ══ T2d: a body over the cap is cut above the block; the block survives ══════
F="$T/t2d-$NOW.md"
head -c 70000 /dev/zero | tr '\0' 'x' > "$F"; printf '\n' >> "$F"
pr_trailers_apply "$F" job-1 BH-1
SZ=$(wc -c < "$F")
[ "$SZ" -le 65000 ] && ok || bad "T2d: the result must fit in 65000 bytes (got $SZ)"
[ "$(tail -n 2 "$F")" = $'Harness-Job: job-1\nHarness-Ticket: BH-1' ] && ok || bad "T2d: the block must be last after a cut"

# ══ T3–T4b: the real `# >>> pr create call` block ════════════════════════════
mkdir -p "$T/bin"
cat > "$T/bin/gh" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$CASE/gh-calls.log"
case "$1 $2" in
  "pr create")
    prev=""
    for a in "$@"; do
      [ "$prev" = --body-file ] && cp "$a" "$CASE/captured.md"
      prev=$a
    done
    echo "https://github.com/example-org/cromford/pull/4014"; exit 0 ;;
esac
for a in "$@"; do case "$a" in body=@*) cp "${a#body=@}" "$CASE/captured.md" ;; esac; done
exit 1
STUB
chmod +x "$T/bin/gh"
PATH="$T/bin:$PATH"
HARNESS="$T/h"; export HARNESS
mkdir -p "$HARNESS/bin/lib"
cp "$LIB" "$DIR/bin/lib/env-path.sh" "$HARNESS/bin/lib/"
marked() { awk -v s="$1" -v e="$2" 'index($0,s){f=1} f{print} f && index($0,e){exit}' "$3"; }
BLK="$T/create-call.sh"
marked '# >>> pr create call' '# <<< pr create call' "$RB_ALL" > "$BLK"
[ -s "$BLK" ] && ok || bad "T3: '# >>> pr create call' is missing from the pipeline"
hold_gate_prepend "$RB_ALL" "$BLK"   # BH-6091: the real gate, a no-HOLD ticket read

new_case() { # new_case <name> -> CASE with a git repo as the build dir
  CASE="$T/case-$1-$NOW"; export CASE
  mkdir -p "$CASE/b"; : > "$CASE/gh-calls.log"
  ( cd "$CASE/b" && git init -q . \
    && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m "the subject" \
    && git remote add origin https://github.com/example-org/cromford.git ) >/dev/null 2>&1
}
create_call() { # create_call [extra bash before the block] — runs the block in $CASE/b
  ( cd "$CASE/b" && BUILD="$CASE/b" PROJECT=cromford KEY=BH-1 BRANCH=ticket/bh-1 \
     BASE=main BASE_MAIN=main ALERTS="$CASE/ALERTS.log" \
     bash -c 'STAMP(){ echo 2026-10-03T00:00:00Z; }; GH_LIVE(){ :; }; EVIDENCE_SECTION=
              PR_BODY_FOR(){ printf "what and why\n\n%s\n" "'"$FOOTER"'"; }
              '"${1-}"'
              . '"$BLK"'; printf "%s\n" "$PR_URL" > "$BUILD/url"' ) >/dev/null 2>"$CASE/stderr"
}
has_trailers() { # has_trailers <job> -> the captured body ends in the block
  [ "$(tail -n 2 "$CASE/captured.md" 2>/dev/null)" = "Harness-Job: $1"$'\nHarness-Ticket: BH-1' ] \
    && [ "$(pr_trailers_read "$CASE/captured.md" 2>/dev/null)" = "$1${TAB}BH-1${TAB}" ]
}

# T3: box build, ladder lib present.
cp "$DIR/bin/lib/gh-pr-create.sh" "$HARNESS/bin/lib/"
new_case box
JOB_ID=job-box-1 create_call
has_trailers job-box-1 && ok || bad "T3 (box, ladder): the PR body gh got must end in the trailers, got: $(tail -n 3 "$CASE/captured.md" 2>/dev/null)"
grep -q -- '--body-file' "$CASE/gh-calls.log" && ok || bad "T3: the ladder must create with --body-file"

# T3c: apply fails -> the PR still opens, one log line.
new_case box-nowrite
mkdir -p "$CASE/nomv"; printf '#!/bin/sh\nexit 1\n' > "$CASE/nomv/mv"; chmod +x "$CASE/nomv/mv"
JOB_ID=job-box-1 create_call 'PATH="$CASE/nomv:$PATH"'
[ "$(cat "$CASE/b/url" 2>/dev/null)" = https://github.com/example-org/cromford/pull/4014 ] && ok \
  || bad "T3c: a trailer that cannot be written must not stop the PR, url: $(cat "$CASE/b/url" 2>/dev/null)"
[ "$(grep -c 'pr trailers: could not write' "$CASE/b/pipeline.log" 2>/dev/null)" = 1 ] && ok \
  || bad "T3c: exactly one 'pr trailers: could not write' line, got: $(cat "$CASE/b/pipeline.log" 2>/dev/null)"
grep -q '^Harness-' "$CASE/captured.md" 2>/dev/null && bad "T3c: the body must have opened without trailers" || ok

# T3d: the trailer lib absent -> PR opens as before, body untouched, no log line.
mv "$HARNESS/bin/lib/pr-trailers.sh" "$T/pr-trailers.away"
new_case box-nolib
JOB_ID=job-box-1 create_call
[ "$(cat "$CASE/captured.md" 2>/dev/null)" = "what and why"$'\n\n'"$FOOTER" ] && ok \
  || bad "T3d: with the lib absent the body must be PR_BODY_FOR's bytes, got: $(cat "$CASE/captured.md" 2>/dev/null)"
grep -q 'pr trailers' "$CASE/b/pipeline.log" 2>/dev/null && bad "T3d: an absent lib must log nothing" || ok
mv "$T/pr-trailers.away" "$HARNESS/bin/lib/pr-trailers.sh"

# T4: pool build — BUILDER_EXEC=1, JOB_ID empty, id only in job.json.
new_case pool
printf '{"job_id":"job-pool-7"}\n' > "$CASE/b/job.json"
BUILDER_EXEC=1 JOB_ID= create_call
has_trailers job-pool-7 && ok || bad "T4 (pool): the job id must come from job.json, got: $(tail -n 3 "$CASE/captured.md" 2>/dev/null)"

# T4b: no job id anywhere -> none.
new_case pool-none
BUILDER_EXEC=1 JOB_ID= create_call
has_trailers none && ok || bad "T4b: no JOB_ID and no job.json must read Harness-Job: none, got: $(tail -n 3 "$CASE/captured.md" 2>/dev/null)"

# T3b: the ladder lib absent -> the else branch, --body-file, trailered.
rm -f "$HARNESS/bin/lib/gh-pr-create.sh"
new_case box-else
JOB_ID=job-box-1 create_call
grep -q -- '--body-file' "$CASE/gh-calls.log" && ok || bad "T3b: the no-ladder create must pass --body-file, calls: $(cat "$CASE/gh-calls.log")"
has_trailers job-box-1 && ok || bad "T3b (box, no ladder): the body must end in the trailers, got: $(tail -n 3 "$CASE/captured.md" 2>/dev/null)"

echo "pr-trailers.bh-3987-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
