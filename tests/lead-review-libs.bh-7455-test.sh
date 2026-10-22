#!/bin/bash
# tests/lead-review-libs.bh-7455-test.sh — BH-7455: the optional libs of
# bin/lead-review.sh are one fragment file each in bin/lib/lead-review/libs.d/,
# and the host sources them at top level in LC_ALL=C name order
# (docs/notes/2026-10-19-BH-7455-lead-review-libs.md).
#
#   S1  sibling merge: two branches each add one fragment the documented way;
#       the merge is clean, the host is untouched, and --print ends with both
#       new bodies in name order. Control: two branches that each append one
#       lib line to the old block conflict.
#   S2  the render equals the file in use before the move: in the commit that
#       added libs.d/, the old host's block equals --print of that tree, and no
#       other host line changed. LR_LIBS_BASE=<rev> also compares <rev>'s block
#       to the working tree's NNNN fragments.
#   S3  bin/lead-review-libs-build.sh --check: the real tree is ok; one fault a
#       scratch dir (bad name, non-.sh entry, header, bash -n, empty dir,
#       duplicate entry, `# module:` line, tracked render, bad args) is rc 1
#       with its finding; S3f: one changed byte in a fragment fails S2's compare.
#   S4  load order = --print order, under LC_ALL=C and en_US.UTF-8.
#   S5  production entry point (D2): scratch_closure_list names every fragment
#       and every lib they source; a real `bin/lead-review.sh tick` runs clean;
#       without 0140-review-level.sh the tick does not load bin/lib/review-level.sh.
#   S6  fail closed: libs.d/ missing, empty, or holding only README.md -> rc 0,
#       one log line, one LEAD REVIEW LIBS MISSING alert, no jobs request.
#   S7  the catalog/list-files.tsv row for bin/lead-review.sh, real lint and
#       real catalog: growth with no new file under bin/lib/lead-review/ is
#       refused; a shrink, a new fragment, a new module, a value edit pass.
#   S8  bin/test-impact.sh selects the host's suites for a fragment-only change.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lead-review-libs.bh-7455-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
BUILD="$DIR/bin/lead-review-libs-build.sh"
LINT="$DIR/bin/list-file-lint.sh"
REL=bin/lib/lead-review/libs.d
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "FAIL: jq missing"; exit 1; }

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.com
export GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.com
export GIT_AUTHOR_DATE='2026-10-19T16:00:00Z' GIT_COMMITTER_DATE='2026-10-19T16:00:00Z'

# frag <root> <name> <body line> — write one fragment the documented way.
frag() {
  mkdir -p "$1/$REL" || return 1
  printf '#!/bin/bash\n# shellcheck shell=bash\n# %s/%s — fixture lib. Sourced at top level, never run.\n%s\n' \
    "$REL" "$2" "$3" > "$1/$REL/$2"
}
# block <host file> — the old optional-lib block: the lines after
# `LW_LOGFN=log`, up to the line before `# BH-5909: the console QA gate.`
block() { awk '/^# BH-5909: the console QA gate\./ { exit } f { print } /^LW_LOGFN=log$/ { f = 1 }' "$1"; }
# outside <host file> — every line but that block.
outside() { awk '/^# BH-5909: the console QA gate\./ { f = 0 } !f { print } /^LW_LOGFN=log$/ { f = 1 }' "$1"; }
# same_as_render <old host> <root> — rc 0 when the old host's block is
# byte-equal to --print over <root>.
same_as_render() {
  local r
  r=$("$BUILD" --root "$2" --print) || return 1
  [ -n "$r" ] && [ "$(block "$1")" = "$r" ]
}

# ── S1. two siblings add an entry each and merge clean ──────────────────────
R="$T/s1"; mkdir -p "$R/bin/lib/lead-review"
if [ -f "$DIR/bin/lead-review.sh" ] && [ -d "$DIR/$REL" ]; then
  cp "$DIR/bin/lead-review.sh" "$R/bin/" && cp -R "$DIR/$REL" "$R/bin/lib/lead-review/"
  # Year-9999 fixture names sort after every real fragment, so --print ends with them.
  (
    cd "$R" && git init -q -b main . && git add -A && git commit -q -m base \
      && git checkout -q -b a && frag . 999912312358-bh-1-a.sh 'echo lib-a' && git add -A && git commit -q -m a \
      && git checkout -q main && git checkout -q -b b && frag . 999912312359-bh-2-b.sh 'echo lib-b' && git add -A && git commit -q -m b \
      && git checkout -q a
  ) || bad "S1: could not build the sibling repo"
  git -C "$R" merge -q --no-edit b > "$T/s1.merge" 2>&1; rc=$?
  [ "$rc" = 0 ] && ok || bad "S1: merging sibling b into a was rc $rc: $(head -3 "$T/s1.merge")"
  ! grep -rlE '^(<<<<<<<|>>>>>>>)' "$R/bin" >/dev/null && ok || bad "S1: conflict markers after the merge"
  cmp -s "$R/bin/lead-review.sh" "$DIR/bin/lead-review.sh" && ok || bad "S1: the merge changed bin/lead-review.sh"
  tail2=$("$BUILD" --root "$R" --print | tail -2 | tr '\n' ' ')
  [ "$tail2" = "echo lib-a echo lib-b " ] && ok || bad "S1: --print does not end with lib-a then lib-b: '$tail2'"
  # Control: the old way, one lib line each after the last entry of the block.
  C="$T/s1c"; mkdir -p "$C"
  { "$BUILD" --print; echo '# BH-5909: the console QA gate.'; } > "$C/host.sh"
  (
    cd "$C" && git init -q -b main . && git add -A && git commit -q -m base \
      && git checkout -q -b a && sed -i '/^# BH-5909/i . "$H/bin/lib/a.sh" 2>/dev/null || true' host.sh && git commit -q -am a \
      && git checkout -q main && git checkout -q -b b && sed -i '/^# BH-5909/i . "$H/bin/lib/b.sh" 2>/dev/null || true' host.sh && git commit -q -am b \
      && git checkout -q a
  ) || bad "S1: could not build the control repo"
  git -C "$C" merge -q --no-edit b > "$T/s1c.merge" 2>&1; rc=$?
  [ "$rc" = 1 ] && grep -q '^<<<<<<<' "$C/host.sh" && ok || bad "S1: the control (two appends to one block) did not conflict (rc $rc)"
else
  bad "S1: no $REL/ in the tree; a new lib can only be a line in bin/lead-review.sh"
fi

# ── S2. the render equals the block it replaced ─────────────────────────────
if git -C "$DIR" rev-parse --git-dir >/dev/null 2>&1; then
  CM=$(git -C "$DIR" log --diff-filter=A --format=%H -- "$REL/0010-llm-gate.sh" 2>/dev/null | tail -1)
  if [ -z "$CM" ] && [ -f "$DIR/$REL/0010-llm-gate.sh" ] && [ "$(git -C "$DIR" rev-parse --is-shallow-repository 2>/dev/null)" = true ]; then
    echo "NOTE: S2 not run (shallow clone: the commit that added $REL/ is not in it)"
  elif [ -z "$CM" ]; then
    bad "S2: no commit added $REL/0010-llm-gate.sh"
  else
    W="$T/s2"; mkdir -p "$W"
    git -C "$DIR" show "$CM^:bin/lead-review.sh" > "$W/old.sh" && git -C "$DIR" show "$CM:bin/lead-review.sh" > "$W/new.sh" \
      && git -C "$DIR" archive "$CM" "$REL" | tar -x -C "$W" || bad "S2: cannot read $CM"
    [ "$(block "$W/old.sh" | wc -l)" -gt 60 ] && ok || bad "S2: the old block between the anchors is not found in $CM^"
    same_as_render "$W/old.sh" "$W" && ok || bad "S2: --print of $CM is not the block of $CM^:bin/lead-review.sh"
    [ "$(outside "$W/old.sh")" = "$(outside "$W/new.sh")" ] && ok \
      || bad "S2: $CM changed bin/lead-review.sh outside the lib block"
    grep -qF "$REL/" <(block "$W/new.sh") && ok || bad "S2: $CM:bin/lead-review.sh has no loader stanza in place of the block"
    # S3f: one changed byte in one fragment fails the same compare.
    cp -R "$W/bin" "$T/s3f-bin" && mkdir -p "$T/s3f" && mv "$T/s3f-bin" "$T/s3f/bin"
    sed -i '4,$s/review level cap/review level cep/' "$T/s3f/$REL/0140-review-level.sh"
    ! cmp -s "$T/s3f/$REL/0140-review-level.sh" "$W/$REL/0140-review-level.sh" && ! same_as_render "$W/old.sh" "$T/s3f" && ok \
      || bad "S3f: a fragment with one changed byte still equals the old block"
  fi
  if [ -n "${LR_LIBS_BASE:-}" ]; then
    B="$T/s2b"; mkdir -p "$B/$REL"
    git -C "$DIR" show "$LR_LIBS_BASE:bin/lead-review.sh" > "$B/old.sh" || bad "S2: LR_LIBS_BASE=$LR_LIBS_BASE has no bin/lead-review.sh"
    for f in "$DIR/$REL"/[0-9][0-9][0-9][0-9]-*.sh; do cp "$f" "$B/$REL/"; done
    same_as_render "$B/old.sh" "$B" && { ok; echo "S2: the 21 NNNN fragments equal the block of $LR_LIBS_BASE"; } \
      || bad "S2: the NNNN fragments are not the block of $LR_LIBS_BASE"
  fi
else
  echo "NOTE: S2 not run (no git history)"
fi

# ── S3. --check ─────────────────────────────────────────────────────────────
n_all=0; n_old=0
for f in "$DIR/$REL"/*.sh; do
  [ -f "$f" ] || continue
  n_all=$((n_all + 1)); [[ ${f##*/} =~ ^[0-9]{4}- ]] && n_old=$((n_old + 1))
done
out=$("$BUILD" --check 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$out" = "lead-review-libs: $n_all fragments ok" ] && [ "$n_old" = 21 ] && ok \
  || bad "S3: --check on the real tree rc=$rc, $n_old NNNN fragments: $out"
# chk <case> <want rc> <want text> — run --check on $T/c/<case>.
chk() {
  OUT=$("$BUILD" --root "$T/c/$1" --check 2>&1); RC=$?
  [ "$RC" = "$2" ] && grep -qF -- "$3" <<<"$OUT" && ok || bad "S3 $1: want rc $2 and '$3', got rc $RC: $OUT"
  [ "$2" = 0 ] || ! grep -q 'fragments ok' <<<"$OUT" && ok || bad "S3 $1: a failing --check still printed 'fragments ok'"
}
base() { mkdir -p "$T/c/$1/$REL" && frag "$T/c/$1" 0010-a.sh 'echo a'; }
for n in 10-x.sh 0010_llm.sh 202610191600-x.sh 0010-X.sh; do
  c="s3a-${n//[^a-zA-Z0-9]/_}"; base "$c"; frag "$T/c/$c" "$n" 'echo n'; chk "$c" 1 "$REL/$n: bad name"
done
for n in 202610191600-bh-7455-x.sh 202610191600-bh-6372.3-x.sh; do
  c="s3ok-${n//[^a-zA-Z0-9]/_}"; base "$c"; frag "$T/c/$c" "$n" 'echo n'; chk "$c" 0 "2 fragments ok"
done
for n in 0010-x.sh.bak README.md; do
  c="s3b-${n//[^a-zA-Z0-9]/_}"; base "$c"; echo x > "$T/c/$c/$REL/$n"; chk "$c" 1 "$REL/$n: not a *.sh fragment"
done
base s3b-dir; mkdir "$T/c/s3b-dir/$REL/0020-d.sh"; chk s3b-dir 1 "$REL/0020-d.sh: not a *.sh fragment"
base s3c; frag "$T/c/s3c" 0020-b.sh 'echo b'; sed -i "3s/0020-b.sh/0030-c.sh/" "$T/c/s3c/$REL/0020-b.sh"; chk s3c 1 "$REL/0020-b.sh: bad header"
base s3c2; frag "$T/c/s3c2" 0020-b.sh 'echo b'; sed -i 1d "$T/c/s3c2/$REL/0020-b.sh"; chk s3c2 1 "$REL/0020-b.sh: bad header"
base s3d; frag "$T/c/s3d" 0020-b.sh 'if then fi'; chk s3d 1 "$REL/0020-b.sh: does not parse"
mkdir -p "$T/c/s3e/$REL"; chk s3e 1 "$REL/: has no fragment"
"$BUILD" --root "$T/c/s3e" --print >/dev/null 2>&1; rc=$?
[ "$rc" = 1 ] && ok || bad "S3e: --print with no fragment rc=$rc, want 1"
mkdir -p "$T/c/s3e2/bin"; chk s3e2 1 "$REL/: has no fragment"
base s3h; frag "$T/c/s3h" 0020-b.sh 'echo a'; chk s3h 1 "$REL/0020-b.sh: the same entry as $REL/0010-a.sh"
base s3i; frag "$T/c/s3i" 0020-b.sh '# module: b'; chk s3i 1 "$REL/0020-b.sh: has a '# module:' line"
base s3g; echo 'echo a' > "$T/c/s3g/bin/lib/lead-review/libs.sh"
( cd "$T/c/s3g" && git init -q -b main . && git add -A && git commit -q -m g ) || bad "S3g: git setup"
chk s3g 1 "bin/lib/lead-review/libs.sh: a render of $REL/ is tracked in git"
"$BUILD" --root "$T/c/s3g" --bogus >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && ok || bad "S3: an unknown flag rc=$rc, want 2"
"$BUILD" --root "$T/c/s3g" >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && ok || bad "S3: no mode rc=$rc, want 2"

# ── the scratch harness for S4-S6: the host's real closure ──────────────────
H="$T/h"; mkdir -p "$H/prompts" "$H/catalog/lanes.d" "$H/state" "$T/fakebin" "$T/log" "$T/tmp"
CL=$(cd "$DIR" && scratch_closure_list bin/lead-review.sh 2>"$T/cl.err"); rc=$?
[ "$rc" = 0 ] && ok || bad "S5: scratch_closure_list bin/lead-review.sh rc=$rc: $(cat "$T/cl.err")"
for s in bin/lead-review.sh bin/jobs-client.sh bin/box-for.sh bin/fleet-conf.sh bin/alert-line.sh; do
  scratch_install_closure "$s" "$H" >/dev/null || bad "closure install of $s"
done
cp "$DIR/catalog/lanes.d/_lib.json" "$H/catalog/lanes.d/"
cp "$DIR/prompts/lead-review.md" "$DIR/prompts/lead-review-checklist.md" "$H/prompts/"
echo box-demo > "$H/state/box-name"
echo 'demo-os example-org/demo-os https://demo.test /api/board 1 box-demo' > "$H/fleet.conf"
cat > "$T/fakebin/curl" <<EOF
#!/bin/bash
url=""; for a in "\$@"; do case "\$a" in http*) url="\$a" ;; esac; done
printf '%s\n' "\${url#https://jobs.test}" >> "$T/log/worker"
case "\$url" in
  *"/api/lead-reviews"*) printf '%s\n200' '{"requests":[],"truncated":false}' ;;
  *) printf '%s\n200' '{}' ;;
esac
EOF
chmod +x "$T/fakebin/curl"
# tick [VAR=value...] — one real tick of the scratch host.
tick() {
  ( export PATH="$T/fakebin:$PATH" HARNESS="$H" HARNESS_SECRET=s-fixture JOBS_URL=https://jobs.test JOBS_RETRIES=0 \
           TMPDIR="$T/tmp" FLEET_CONF="$H/fleet.conf" LANE_GATE_DISABLE=1 GH_ETAG=0 _VP_WINDOW=40 "$@"
    unset BOX_NAME JOBS_BOX HARNESS_PARTICIPANT_TOKEN_FILE
    cd "$T" && bash "$H/bin/lead-review.sh" tick ) > "$T/out" 2>&1
}
fresh() { rm -f "$T/log/worker" "$H/logs/lead-review.log" "$H/logs/ALERTS.log" "$T/order" "$T/rl"; }
cnt() { local c; c=$(grep -c "$1" "$2" 2>/dev/null); echo "${c:-0}"; }

# ── S5. the production entry point loads the fragments ──────────────────────
want_libs=$(sed -n -E 's/.*\. "\$H\/(bin\/lib\/[a-z0-9-]+\.sh)".*/\1/p' "$DIR/$REL"/*.sh | LC_ALL=C sort -u)
[ "$(grep -c . <<<"$want_libs")" = 22 ] && ok || bad "S5: the fragments should source 22 libs (21 NNNN + 202610211850-bh-7667), found: $(tr '\n' ' ' <<<"$want_libs")"
for f in "$DIR/$REL"/*.sh; do
  grep -qxF "$REL/${f##*/}" <<<"$CL" && ok || bad "S5: scratch_closure_list bin/lead-review.sh does not list $REL/${f##*/}"
done
for l in $want_libs; do
  grep -qxF "$l" <<<"$CL" && ok || bad "S5: scratch_closure_list bin/lead-review.sh does not list $l"
done
printf '\necho rl-canary >> "%s"\n' "$T/rl" >> "$H/bin/lib/review-level.sh"
fresh; tick; rc=$?
[ "$rc" = 0 ] && ok || bad "S5: a tick with every fragment exited $rc ($(tail -3 "$T/out"))"
[ "$(cnt 'has no fragment' "$H/logs/lead-review.log")" = 0 ] && ok || bad "S5: a tick with every fragment logged 'has no fragment'"
grep -q '/api/lead-reviews' "$T/log/worker" 2>/dev/null && ok || bad "S5: the tick never read the lead-review list ($(tail -3 "$H/logs/lead-review.log" 2>/dev/null))"
[ "$(cnt rl-canary "$T/rl")" = 1 ] && ok || bad "S5: the tick did not source bin/lib/review-level.sh once through its fragment"
mv "$H/$REL/0140-review-level.sh" "$T/0140.saved"
fresh; tick; rc=$?
[ "$rc" = 0 ] && [ ! -e "$T/rl" ] && ok || bad "S5: with 0140-review-level.sh gone the tick still sourced bin/lib/review-level.sh (rc $rc)"
mv "$T/0140.saved" "$H/$REL/0140-review-level.sh"

# ── S4. load order = --print order, whatever the locale ─────────────────────
CAN=(0010-a.sh 202610191600-bh-7455-a.sh 202610191600-bh-74550-a.sh)
for n in "${CAN[@]}"; do frag "$H" "$n" "echo $n >> \"$T/order\""; done
want=$("$BUILD" --root "$H" --print | sed -n -E 's/^echo ([^ ]+) >> .*/\1/p' | tr '\n' ' ')
[ "$want" = "${CAN[*]} " ] && ok || bad "S4: --print order is '$want', want '${CAN[*]} '"
fresh; tick LC_ALL=C; rc=$?
got=$(tr '\n' ' ' < "$T/order" 2>/dev/null)
[ "$rc" = 0 ] && [ "$got" = "$want" ] && ok || bad "S4: under LC_ALL=C the tick loaded '$got', want '$want' (rc $rc)"
if locale -a 2>/dev/null | grep -qiE '^en_US\.utf-?8$'; then
  fresh; tick LC_ALL=en_US.UTF-8; got=$(tr '\n' ' ' < "$T/order" 2>/dev/null)
  [ "$got" = "$want" ] && ok || bad "S4: under LC_ALL=en_US.UTF-8 the tick loaded '$got', want '$want'"
else
  echo "NOTE: S4 en_US.UTF-8 not run (locale -a has no en_US.UTF-8)"
fi
for n in "${CAN[@]}"; do rm -f "$H/$REL/$n"; done

# ── S6. no fragment: rc 0, one log line, one alert, no request ──────────────
s6() {
  fresh; tick; local rc=$?
  [ "$rc" = 0 ] && ok || bad "S6 $1: the tick exited $rc, want 0"
  [ "$(cnt "$REL/ has no fragment; lead-review tick skipped" "$H/logs/lead-review.log")" = 1 ] && ok \
    || bad "S6 $1: want one 'has no fragment' log line ($(tail -2 "$H/logs/lead-review.log" 2>/dev/null))"
  [ "$(cnt 'LEAD REVIEW LIBS MISSING' "$H/logs/ALERTS.log")" = 1 ] && ok \
    || bad "S6 $1: want one LEAD REVIEW LIBS MISSING alert line, got $(cnt 'LEAD REVIEW LIBS MISSING' "$H/logs/ALERTS.log")"
  [ ! -s "$T/log/worker" ] && ok || bad "S6 $1: a skipped tick sent a request: $(head -3 "$T/log/worker")"
}
mv "$H/$REL" "$T/libs.saved"
s6 missing
mkdir "$H/$REL"; s6 empty
echo note > "$H/$REL/README.md"; s6 readme-only
scratch_rm "$H/$REL" || exit 1; mv "$T/libs.saved" "$H/$REL"
fresh; tick; [ "$(cnt 'has no fragment' "$H/logs/lead-review.log")" = 0 ] && ok || bad "S6: the restored harness still skips the tick"

# ── S7. the list-file row, real lint and real catalog ───────────────────────
grep -qP '^bin/lead-review\.sh\tbin/lib/lead-review/\t' "$DIR/catalog/list-files.tsv" && ok \
  || bad "S7: catalog/list-files.tsv has no 'bin/lead-review.sh<TAB>bin/lib/lead-review/' row"
# s7 <case> — a repo at $T/s7/<case> with the base commit on branch `base`.
s7() {
  local R="$T/s7/$1"
  mkdir -p "$R/catalog" "$R/bin/lib/lead-review" && cd "$R" || return 1
  git init -q -b main .
  cp "$DIR/catalog/list-files.tsv" catalog/
  cp "$DIR/bin/lead-review.sh" bin/ && cp -R "$DIR/$REL" bin/lib/lead-review/
  git add -A && git commit -q -m base && git branch base
}
s7run() {
  git add -A && git commit -q -m pr
  OUT=$("$LINT" --base base 2>&1); RC=$?; cd "$T" || exit 1
  if [ "$2" = 1 ]; then
    [ "$RC" = 1 ] && grep -qF 'bin/lead-review.sh grew' <<<"$OUT" && ok || bad "S7 $1: want rc 1 naming bin/lead-review.sh, got rc $RC: $OUT"
  else
    [ "$RC" = 0 ] && ok || bad "S7 $1: want rc 0, got rc $RC: $OUT"
  fi
}
add2() { printf 'echo x\necho y\n' >> bin/lead-review.sh; }
s7 grow-only && add2 && s7run grow-only 1
s7 near-miss && add2 && mkdir -p bin/lib/lead-review.d && echo x > bin/lib/lead-review.d/x.sh && s7run near-miss 1
s7 edited-frag && add2 && echo '# edit' >> "$REL/0010-llm-gate.sh" && s7run edited-frag 1
s7 shrink && sed -i '1,5d' bin/lead-review.sh && s7run shrink 0
s7 new-frag && frag . 202610191600-bh-1-x.sh 'echo x' && s7run new-frag 0
s7 new-module && add2 && echo 'x() { :; }' > bin/lib/lead-review/x.sh && s7run new-module 0
s7 value-edit && sed -i 's/^LW_LOGFN=log$/LW_LOGFN=logx/' bin/lead-review.sh && s7run value-edit 0
cd "$T" || exit 1

# ── S8. a fragment-only change selects the host's suites ────────────────────
# The map row names libs.d/ itself: the host's own source line gives the edge
# bin/lead-review.sh -> bin/lib/lead-review/libs.d/ (the module-dir edge of
# load.sh alone gives only bin/lib/lead-review/).
"$DIR/bin/test-impact.sh" --root "$DIR" map > "$T/map" 2>"$T/map.err"; rc=$?
[ "$rc" = 0 ] && grep -qxP "tests/lead-review-lane\.bh-1950-test\.sh\t$REL/" "$T/map" && ok \
  || bad "S8: the test-impact map has no 'tests/lead-review-lane.bh-1950-test.sh<TAB>$REL/' row (rc $rc): $(tail -2 "$T/map.err")"
echo "$REL/0140-review-level.sh" > "$T/changed"
"$DIR/bin/test-impact.sh" --root "$DIR" --map "$T/map" select --changed "$T/changed" --map-only > "$T/sel" 2>"$T/sel.err"; rc=$?
[ "$rc" = 0 ] && grep -qxF tests/lead-review-lane.bh-1950-test.sh "$T/sel" && ok \
  || bad "S8: a change to $REL/0140-review-level.sh does not select tests/lead-review-lane.bh-1950-test.sh (rc $rc): $(tail -2 "$T/sel.err")"

echo "lead-review-libs.bh-7455: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
