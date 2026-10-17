#!/bin/bash
# tests/share-release-notes.bh-7185-test.sh — each public release commit
# carries bullet release notes built from the PR titles merged since the last
# release (BH-7185).
#
# bin/share/release_message.py in notes mode (--notes-repo, --previous-subject)
# reads the upstream sha out of the published head's subject, lists the PRs
# merged on the first-parent line between it and the new sha, strips ticket
# keys and PR numbers, runs each title through sanitize.rewrite, and DROPS a
# title that names anybody. bin/publish-share.sh passes the published head's
# subject, and leakcheck still runs over the whole message.
#
#   R1  3 merged PRs + 1 direct commit -> header, blank, 3 bullets in merge order, no keys, no '#'
#   R1b a title with a mapped host comes out with the placeholder
#   R1c inline '#<n>' refs and a bracketed key are stripped, the words kept
#   R2  a title with a project token, or a box name, is dropped and counted; rc 0, no token echoed
#   R3  a title with a credential shape -> leakcheck refuses that message; the publisher
#       retries once with the fallback bullet (TEST-CHANGE, lead review); R3b: a
#       credential in --summary still refuses rc 1, nothing pushed
#   R4  45 PRs -> 40 bullets + '- and 5 more changes'; 40 PRs -> no 'and' line; 41 -> 'and 1 more'
#   R5  unreadable previous subject (seed, empty, unknown sha, not an ancestor) -> one fallback bullet, rc 0
#   R6  notes mode keeps the summary refusals (forbidden wording, two lines) rc 1, empty stdout
#   R7  a readable previous sha with no PRs in range -> header only
#   R8  a bounded name, a tailnet address, a 32-hex id -> each bullet dropped and counted
#   N1  an exception in the notes code -> the fallback bullet, rc 0
#   N2  no '(slice 2 of )' or bare 's left after a key is stripped
#   N3  'Security:', 'HOTFIX', 'can forge' titles are internal: dropped and counted
#   N4  a long title is cut at the last whole word plus '…'
#   N5  a title the harness cut at 80 ends at a whole word plus '…'; '( follow-up)' tidied;
#       a merge-commit title is not listed
#   P1  real publisher --dry-run prints the bullets and the drop count
#   P2  two real publishes: the second commit lists only the PR merged between them
#
# Name tokens and the credential shape are built at runtime from mapping.py,
# so this file carries no literal name and passes the mirror's own leakcheck.
#
# Run from anywhere: tests/share-release-notes.bh-7185-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

if [ ! -f "$DIR/bin/publish-share.sh" ] || [ ! -f "$DIR/bin/share/release_message.py" ]; then
  echo "SKIP share-release-notes: no bin/publish-share.sh or bin/share/release_message.py in this copy"
  exit 0
fi

unset SHARE_MIRROR_REPO
export GIT_CONFIG_GLOBAL="$T/gitconfig" GIT_CONFIG_NOSYSTEM=1
printf '[init]\n\tdefaultBranch = main\n' > "$GIT_CONFIG_GLOBAL"
export GIT_AUTHOR_DATE="2026-10-17T00:00:00Z" GIT_COMMITTER_DATE="2026-10-17T00:00:00Z"
RM="$DIR/bin/share/release_message.py"
gc() { git -c user.name=t -c user.email=t@example.com "$@"; }
mapq() { # <python expr over mapping/sanitize/has_name> — read the tables at runtime
  (cd "$DIR/bin/share" && python3 -I -c "import sys; sys.path.insert(0, '.'); import mapping, sanitize; from release_message import has_name; print($1)")
}
PTOK=$(mapq 'sorted(t for t in mapping.NAME_TOKENS if len(t) > 4 and t.isalpha())[0]')
BOX=$(mapq 'mapping.BOXES[0][0]')
HOST=$(mapq '[a for a, _ in mapping.DOMAINS if not has_name(a) and sanitize.rewrite(a) != a][0]')
HOSTREP=$(mapq "sanitize.rewrite('$HOST')")
[ -n "$PTOK" ] && [ -n "$BOX" ] && [ -n "$HOST" ] && [ -n "$HOSTREP" ] && ok \
  || bad "fixture: could not read a name token, a box name and a mapped host from mapping.py"

# prmerge <repo> <n> <title> — a GitHub-style merge commit for PR #n
prmerge() {
  gc -C "$1" checkout -q -b "pr$2" main
  echo "$2" > "$1/pr$2.txt"
  gc -C "$1" add "pr$2.txt" && gc -C "$1" commit -qm "work for $2"
  gc -C "$1" checkout -q main
  gc -C "$1" merge -q --no-ff "pr$2" -m "Merge pull request #$2 from org/ticket/bh-$2" -m "$3"
}
notes() { # <new> <previous-subject> [args…] — rc to stdout, output in $T/out, $T/err
  local new=$1 prev=$2; shift 2
  python3 -I "$RM" "$new" --date 2026.10.17 --notes-repo "$G" --previous-subject "$prev" "$@" > "$T/out" 2> "$T/err"
  echo $?
}
body() { sed -n '3,$p' "$T/out"; }

# ── the scratch repo ─────────────────────────────────────────────────────────
G="$T/g"
gc init -q -b main "$G"
echo base > "$G/base.txt"; gc -C "$G" add -A; gc -C "$G" commit -qm "base"
PREV=$(git -C "$G" rev-parse HEAD)
prmerge "$G" 101 "BH-101: BH-100.2: faster triage"
echo x > "$G/x.txt"; gc -C "$G" add -A; gc -C "$G" commit -qm "Fix x (#55)"
echo s > "$G/s.txt"; gc -C "$G" add -A; gc -C "$G" commit -qm "restamp schema fragments (no SQL change)"
prmerge "$G" 102 "merge conductor: lease"
NEW=$(git -C "$G" rev-parse HEAD)
SUBJ="Cromford 2026.10.16 (upstream ${PREV:0:12})"

# R1
rc=$(notes "$NEW" "$SUBJ")
EXP=$(printf 'Cromford 2026.10.17 (upstream %s)\n\n- faster triage\n- Fix x\n- merge conductor: lease' "${NEW:0:12}")
if [ "$rc" = 0 ] && [ "$(cat "$T/out")" = "$EXP" ]; then ok
else bad "R1 expected header, blank, 3 bullets in merge order (rc=$rc): $(tr '\n' '|' < "$T/out") $(cat "$T/err")"; fi
grep -qiE 'BH-|#' "$T/out" && bad "R1 a ticket key or a '#' ref survived: $(tr '\n' '|' < "$T/out")" || ok
# the 40-hex form of the previous subject reads the same
rc=$(notes "$NEW" "Cromford 2026.10.16 (upstream $PREV)")
[ "$rc" = 0 ] && [ "$(cat "$T/out")" = "$EXP" ] && ok || bad "R1 a 40-hex previous sha should read the same (rc=$rc): $(tr '\n' '|' < "$T/out")"

# R1b a mapped host is rewritten, not dropped
P1B=$NEW
prmerge "$G" 103 "Move probes to $HOST"
rc=$(notes "$(git -C "$G" rev-parse HEAD)" "Cromford 2026.10.16 (upstream ${P1B:0:12})")
if [ "$rc" = 0 ] && [ "$(body)" = "- Move probes to $HOSTREP" ] && ! grep -qF "$HOST" "$T/out"; then ok
else bad "R1b a mapped host should come out as its placeholder (rc=$rc): $(body | tr '\n' '|')"; fi

# R1c inline PR refs and keys inside brackets go, the words stay
P1C=$(git -C "$G" rev-parse HEAD)
prmerge "$G" 108 "Retry the queue (#88, BH-90) and refs #87"
rc=$(notes "$(git -C "$G" rev-parse HEAD)" "Cromford 2026.10.16 (upstream ${P1C:0:12})")
[ "$rc" = 0 ] && [ "$(body)" = "- Retry the queue and refs" ] && ok \
  || bad "R1c inline PR refs and bracketed keys must be stripped (rc=$rc): $(body | tr '\n' '|')"

# R2 a project token, and a box name, are dropped and counted
P2B=$(git -C "$G" rev-parse HEAD)
prmerge "$G" 104 "Ship the $PTOK intake"
prmerge "$G" 105 "keep the release lane green"
rc=$(notes "$(git -C "$G" rev-parse HEAD)" "Cromford 2026.10.16 (upstream ${P2B:0:12})")
if [ "$rc" = 0 ] && [ "$(body)" = "$(printf -- '- keep the release lane green\n- 1 internal changes not listed')" ] \
   && ! grep -qiF "$PTOK" "$T/out" "$T/err" && grep -q 'dropped 1 bullet' "$T/err"; then ok
else bad "R2 a project-token title must be dropped and counted, never echoed (rc=$rc): $(body | tr '\n' '|')"; fi
P2C=$(git -C "$G" rev-parse HEAD)
prmerge "$G" 106 "Restart $BOX after the upgrade"
prmerge "$G" 107 "Regenerate the mirror tree"
rc=$(notes "$(git -C "$G" rev-parse HEAD)" "Cromford 2026.10.16 (upstream ${P2C:0:12})")
if [ "$rc" = 0 ] && [ "$(body)" = "- 2 internal changes not listed" ] \
   && ! grep -qiF "$BOX" "$T/out" "$T/err" && ! grep -qi 'mirror' "$T/out"; then ok
else bad "R2 a box name and a forbidden word must each drop their bullet (rc=$rc): $(body | tr '\n' '|')"; fi

# R4 the cap
G4="$T/g4"
gc init -q -b main "$G4"
echo base > "$G4/base.txt"; gc -C "$G4" add -A; gc -C "$G4" commit -qm "base"
B4=$(git -C "$G4" rev-parse HEAD)
for i in $(seq 1 45); do
  prmerge "$G4" "$((200+i))" "change number $i"
  [ "$i" = 40 ] && C40=$(git -C "$G4" rev-parse HEAD)
  [ "$i" = 41 ] && C41=$(git -C "$G4" rev-parse HEAD)
done
C45=$(git -C "$G4" rev-parse HEAD)
G_SAVE=$G; G=$G4
rc=$(notes "$C45" "Cromford 2026.10.16 (upstream ${B4:0:12})")
if [ "$rc" = 0 ] && [ "$(body | grep -c '^- change number ')" = 40 ] \
   && [ "$(body | sed -n 40p)" = "- change number 40" ] \
   && [ "$(body | sed -n 41p)" = "- and 5 more changes" ] && [ "$(body | wc -l | tr -d ' ')" = 41 ]; then ok
else bad "R4 45 PRs must give 40 bullets and '- and 5 more changes' (rc=$rc): $(body | tail -3 | tr '\n' '|')"; fi
rc=$(notes "$C40" "Cromford 2026.10.16 (upstream ${B4:0:12})")
[ "$rc" = 0 ] && [ "$(body | wc -l | tr -d ' ')" = 40 ] && ! grep -q '^- and ' <<<"$(body)" && ok \
  || bad "R4 40 PRs must give 40 bullets and no 'and' line (rc=$rc): $(body | tail -2 | tr '\n' '|')"
rc=$(notes "$C41" "Cromford 2026.10.16 (upstream ${B4:0:12})")
[ "$rc" = 0 ] && [ "$(body | tail -1)" = "- and 1 more changes" ] && ok \
  || bad "R4 41 PRs must end '- and 1 more changes' (rc=$rc): $(body | tail -2 | tr '\n' '|')"
G=$G_SAVE

# R5 the previous sha cannot be read
OTHER="$T/other"
gc init -q -b main "$OTHER"; echo o > "$OTHER/o.txt"; gc -C "$OTHER" add -A; gc -C "$OTHER" commit -qm o
gc -C "$G" fetch -q "$OTHER" main:refs/heads/unrelated
UNREL=$(git -C "$G" rev-parse unrelated)
for prev in "seed" "" "Cromford 2026.10.16 (upstream 0123456789ab)" "Cromford 2026.10.16 (upstream ${UNREL:0:12})"; do
  rc=$(notes "$NEW" "$prev")
  if [ "$rc" = 0 ] && [ "$(sed -n 1p "$T/out")" = "Cromford 2026.10.17 (upstream ${NEW:0:12})" ] \
     && [ "$(body)" = "- release notes unavailable for this build" ]; then ok
  else bad "R5 previous subject '$prev' must give the one fallback bullet, rc 0 (rc=$rc): $(tr '\n' '|' < "$T/out")"; fi
done
rc=$(python3 -I "$RM" "$NEW" --date 2026.10.17 --notes-repo "$T/not-a-repo" --previous-subject "$SUBJ" > "$T/out" 2> "$T/err"; echo $?)
[ "$rc" = 0 ] && [ "$(body)" = "- release notes unavailable for this build" ] && ok \
  || bad "R5 an unreadable notes repo must give the fallback bullet, rc 0 (rc=$rc): $(tr '\n' '|' < "$T/out")"

# R6 the summary refusals hold in notes mode
for s in "regenerated mirror" $'line one\nline two' "Work for $PTOK"; do
  rc=$(notes "$NEW" "$SUBJ" --summary "$s")
  [ "$rc" = 1 ] && [ ! -s "$T/out" ] && ! grep -qiF "$PTOK" "$T/err" && ok \
    || bad "R6 a refused summary must stay rc 1 with empty stdout in notes mode (rc=$rc)"
done
rc=$(notes "$NEW" "$SUBJ" --summary "Faster triage")
[ "$rc" = 0 ] && [ "$(sed -n 3p "$T/out")" = "Faster triage" ] && [ -z "$(sed -n 4p "$T/out")" ] \
  && [ "$(sed -n 5p "$T/out")" = "- faster triage" ] && ok \
  || bad "R6 a kept summary is line 3, then a blank, then the bullets (rc=$rc): $(tr '\n' '|' < "$T/out")"

# R7 a readable previous sha with nothing merged since
rc=$(notes "$NEW" "Cromford 2026.10.16 (upstream ${NEW:0:12})")
[ "$rc" = 0 ] && [ "$(cat "$T/out")" = "Cromford 2026.10.17 (upstream ${NEW:0:12})" ] && ok \
  || bad "R7 an empty range must give the header only (rc=$rc): $(tr '\n' '|' < "$T/out")"

# R8 (lead review) every identity class leakcheck refuses drops its bullet;
# it never reaches leakcheck, which would refuse the whole message and freeze
# the mirror on the same range at every later publish. Tokens built at runtime.
lkq() { # <python expr over leakcheck/has_name>
  (cd "$DIR/bin/share" && python3 -I -c "import sys; sys.path.insert(0, '.'); import leakcheck; from release_message import has_name; print($1)")
}
BTOK=$(lkq 'sorted(sorted((t for t in leakcheck.BOUNDED if t.isalpha() and not has_name(t)), key=len) or sorted(leakcheck.BOUNDED))[0]')
TN="100.$((60+4)).$((1+1)).9"
HEX32=$(printf 'ab%.0s' $(seq 16))
[ -n "$BTOK" ] && ok || bad "R8 fixture: no bounded token in leakcheck"
P8=$(git -C "$G" rev-parse HEAD)
prmerge "$G" 111 "Ask $BTOK about the lane"
prmerge "$G" 112 "Probe $TN health"
prmerge "$G" 113 "Rename the $HEX32 project row"
prmerge "$G" 114 "keep the merge lane honest"
rc=$(notes "$(git -C "$G" rev-parse HEAD)" "Cromford 2026.10.16 (upstream ${P8:0:12})")
if [ "$rc" = 0 ] && [ "$(body)" = "$(printf -- '- keep the merge lane honest\n- 3 internal changes not listed')" ] \
   && ! grep -qiwF "$BTOK" "$T/out" "$T/err" && ! grep -qF "$TN" "$T/out" "$T/err" && ! grep -qF "$HEX32" "$T/out" "$T/err"; then ok
else bad "R8 a bounded name, a tailnet address and a 32-hex id must each drop their bullet, rc 0 (rc=$rc): $(body | tr '\n' '|')"; fi
mkdir -p "$T/msg8" && cp "$T/out" "$T/msg8/COMMIT_MSG.txt"
python3 -I "$DIR/bin/share/leakcheck.py" "$T/msg8" >/dev/null 2>&1 && ok \
  || bad "R8 leakcheck must pass the message once the identity bullets are dropped"

# N1 (lead review) a notes failure never refuses the release: an exception in
# the notes code gives the fallback bullet, rc 0
BRK="$T/brk"; mkdir -p "$BRK"
cp "$DIR/bin/share/release_message.py" "$DIR/bin/share/mapping.py" "$DIR/bin/share/leakcheck.py" "$BRK/"
printf 'def rewrite(text):\n    raise RuntimeError("boom")\n' > "$BRK/sanitize.py"
rc=$(python3 -I "$BRK/release_message.py" "$NEW" --date 2026.10.17 --notes-repo "$G" --previous-subject "$SUBJ" > "$T/out" 2> "$T/err"; echo $?)
[ "$rc" = 0 ] && [ "$(body)" = "- release notes unavailable for this build" ] && ok \
  || bad "N1 an exception in the notes code must give the fallback bullet, rc 0 (rc=$rc): $(tr '\n' '|' < "$T/out") $(tail -1 "$T/err")"

# N2 (lead review) no dangling fragment after a key is stripped
P9=$(git -C "$G" rev-parse HEAD)
prmerge "$G" 115 "Split the queue (slice 2 of BH-7000)"
prmerge "$G" 116 "Move the rest of BH-7001's lanes"
rc=$(notes "$(git -C "$G" rev-parse HEAD)" "Cromford 2026.10.16 (upstream ${P9:0:12})")
[ "$rc" = 0 ] && [ "$(body)" = "$(printf -- '- Split the queue\n- Move the rest of lanes')" ] && ok \
  || bad "N2 a stripped key must leave no '(… of )' and no bare 's (rc=$rc): $(body | tr '\n' '|')"

# N3 (lead review) security write-ups and hotfix notes stay internal
P10=$(git -C "$G" rev-parse HEAD)
prmerge "$G" 117 "Security: close the open probe"
prmerge "$G" 118 "BH-7002: HOTFIX restore the lane"
prmerge "$G" 119 "Stop a worker that can forge a review"
prmerge "$G" 120 "Tidy the lane docs"
rc=$(notes "$(git -C "$G" rev-parse HEAD)" "Cromford 2026.10.16 (upstream ${P10:0:12})")
[ "$rc" = 0 ] && [ "$(body)" = "$(printf -- '- Tidy the lane docs\n- 3 internal changes not listed')" ] && ok \
  || bad "N3 Security:/HOTFIX/'can forge' titles must be dropped and counted (rc=$rc): $(body | tr '\n' '|')"

# N4 (lead review) a long title is cut at the last whole word, plus '…'
P11=$(git -C "$G" rev-parse HEAD)
LONG="Make the lane $(printf 'wordy %.0s' $(seq 30))end"
prmerge "$G" 121 "$LONG"
rc=$(notes "$(git -C "$G" rev-parse HEAD)" "Cromford 2026.10.16 (upstream ${P11:0:12})")
B=$(body); CUT=${B#- }; CUT=${CUT%…}
if [ "$rc" = 0 ] && [ "$CUT" != "${B#- }" ] && [ "${#B}" -le 126 ] && [ "${CUT% }" = "$CUT" ] \
   && [ "${LONG#"$CUT"}" != "$LONG" ] && case "${LONG#"$CUT"}" in " "*) true ;; *) false ;; esac; then ok
else bad "N4 a long title must be cut at a whole word and end in '…' (rc=$rc): $B"; fi

# N5 (lead review) a title the harness already cut (KEY + the first 80
# characters) loses its partial last word and any unclosed bracket, plus '…';
# a "( follow-up)" left by a key loses its inner space; a merge-commit title
# is not a change
P12=$(git -C "$G" rev-parse HEAD)
CUT80="Queue CI reader: a check-run with completed_at and conclusion (success) counts as green when"
CUT80=${CUT80:0:80}
prmerge "$G" 122 "BH-7003: $CUT80"
CUT80B="Merge origin/main into a PR branch only on a real conflict (a clean merge resets the"
prmerge "$G" 123 "BH-7004: ${CUT80B:0:80}"
prmerge "$G" 124 "Shard sizing to 10 min (BH-7005 follow-up)"
prmerge "$G" 125 "BH-7006: Merge remote-tracking branch 'origin/main' into HEAD"
rc=$(notes "$(git -C "$G" rev-parse HEAD)" "Cromford 2026.10.16 (upstream ${P12:0:12})")
EXP5=$(printf -- '- Queue CI reader: a check-run with completed_at and conclusion (success) counts…\n- Merge origin/main into a PR branch only on a real conflict…\n- Shard sizing to 10 min (follow-up)\n- 1 internal changes not listed')
[ "$rc" = 0 ] && [ "$(body)" = "$EXP5" ] && ok \
  || bad "N5 cut titles end at a whole word plus '…', no '( ', no merge-commit bullet (rc=$rc): $(body | tr '\n' '|')"

# ── the real publisher (P1, P2, R3) ──────────────────────────────────────────
# As tests/publish-cromford-append.bh-4901-test.sh: a scratch upstream, the
# public https URL rerouted to a local bare repo. sanitize's tree pass is a
# copy, but its rewrite() is the real one; leakcheck is the real one on the
# message and a no-op on the tree; gitleaks and the registry guard are no-ops.
export GH_TOKEN=dummy-not-used
mkdir -p "$T/stub"
printf '#!/bin/sh\nexit 0\n' > "$T/stub/gh"; chmod +x "$T/stub/gh"
export PATH="$T/stub:$PATH"
URL="https://github.com/cromford-ai/cromford.git"
UP="$T/up"
mkdir -p "$UP/bin/share" "$UP/catalog" "$UP/tests"
cp "$DIR/bin/publish-share.sh" "$UP/bin/"
cp "$DIR/bin/share/mapping.py" "$DIR/bin/share/release_message.py" "$UP/bin/share/"
cp "$DIR/catalog/share-publish-targets.conf" "$UP/catalog/"
cat > "$UP/bin/share/sanitize.py" <<PY
import importlib.util, os, shutil, sys
_s = importlib.util.spec_from_file_location("_real_sanitize", "$DIR/bin/share/sanitize.py")
_m = importlib.util.module_from_spec(_s); _s.loader.exec_module(_m)
rewrite = _m.rewrite
if __name__ == "__main__":
    src, out = sys.argv[1], sys.argv[2]
    shutil.rmtree(out, ignore_errors=True)
    def skip(d, names):
        rel = os.path.relpath(d, src)
        return [n for n in names if n == ".git" or (rel == "bin" and n in ("share", "publish-share.sh"))]
    shutil.copytree(src, out, ignore=skip)
PY
# Imported (release_message.py reads its patterns) it is the real module; run,
# it is the real scan on the message and a no-op on the tree.
cat > "$UP/bin/share/leakcheck.py" <<PY
import importlib.util, runpy, sys
_s = importlib.util.spec_from_file_location("_real_leakcheck", "$DIR/bin/share/leakcheck.py")
_m = importlib.util.module_from_spec(_s); _s.loader.exec_module(_m)
globals().update({k: v for k, v in vars(_m).items() if not k.startswith("__")})
if __name__ == "__main__" and sys.argv[1].endswith("/msg"):
    sys.argv[0] = "$DIR/bin/share/leakcheck.py"
    runpy.run_path(sys.argv[0], run_name="__main__")
PY
for g in gitleaks-gate registry_guard; do printf 'import sys\nsys.exit(0)\n' > "$UP/bin/share/$g.py"; done
printf '#!/bin/bash\nexit 0\n' > "$UP/tests/no-client-identifiers-test.sh"
echo "first" > "$UP/content.txt"
gc init -q -b main "$UP"
gc -C "$UP" add -A && gc -C "$UP" commit -qm "upstream one"
PUB="$T/public.git"
git init -q --bare -b main "$PUB"
SEEDW="$T/seed"
gc init -q -b main "$SEEDW"; echo old > "$SEEDW/old.txt"
gc -C "$SEEDW" add -A && gc -C "$SEEDW" commit -qm "seed" && git -C "$SEEDW" push -q "$PUB" main:main
printf '[init]\n\tdefaultBranch = main\n[url "file://%s"]\n\tinsteadOf = %s\n' "$PUB" "$URL" > "$GIT_CONFIG_GLOBAL"
pub() { bash "$UP/bin/publish-share.sh" --repo cromford-ai/cromford --ref HEAD "$@" > "$T/last.out" 2>&1; echo $?; }
show() { tail -8 "$T/last.out" | tr '\n' ' '; }

# first publish onto the seed: its subject names no upstream sha
rc=$(pub)
UP1=$(git -C "$UP" rev-parse HEAD)
if [ "$rc" = 0 ] && [ "$(git -C "$PUB" log -1 --format=%B main | sed -n 3p)" = "- release notes unavailable for this build" ]; then ok
else bad "P0 the first publish onto a seed must carry the fallback bullet (rc=$rc): $(show)"; fi
H1=$(git -C "$PUB" rev-parse main)

prmerge "$UP" 301 "BH-301: Add a lease timeout"
prmerge "$UP" 302 "Retry $BOX builds"

# P1 the dry-run prints the full message
rc=$(pub --dry-run)
if [ "$rc" = 0 ] && grep -qxF "    - Add a lease timeout" "$T/last.out" \
   && grep -qxF "    - 1 internal changes not listed" "$T/last.out" \
   && grep -q '^release_message: dropped 1 bullet' "$T/last.out" \
   && grep -qxE "    Cromford [0-9]{4}\.[0-9]{2}\.[0-9]{2} \(upstream $(git -C "$UP" rev-parse --short=12 HEAD)\)" "$T/last.out" \
   && ! grep -qiF "$BOX" "$T/last.out" && [ "$(git -C "$PUB" rev-parse main)" = "$H1" ]; then ok
else bad "P1 --dry-run must print the header, the bullet and the drop count, and push nothing (rc=$rc): $(show)"; fi

# P2 a real publish: the body lists only what merged since UP1
rc=$(pub)
MSG=$(git -C "$PUB" log -1 --format=%B main)
if [ "$rc" = 0 ] && [ "$(git -C "$PUB" rev-parse 'main^')" = "$H1" ] \
   && [ "$(sed -n '3,$p' <<<"$MSG")" = "$(printf -- '- Add a lease timeout\n- 1 internal changes not listed')" ]; then ok
else bad "P2 the second publish must list only the PR merged since the first (rc=$rc): $(tr '\n' '|' <<<"$MSG") $(show)"; fi
[ "${UP1:0:12}" != "$(git -C "$UP" rev-parse --short=12 HEAD)" ] && ok || bad "P2 fixture: the upstream did not move"
H2=$(git -C "$PUB" rev-parse main)

# R3 a credential shape in a title: leakcheck refuses the whole notes message.
# TEST-CHANGE (lead review): a refusal does not move the published head, so the
# same range would refuse at every later publish and freeze the mirror. The
# publisher now retries once with the fallback bullet: the credential never
# ships, the refusal is logged, and the release goes out.
CRED="ghp_$(printf 'Ab%.0s' $(seq 18))"
prmerge "$UP" 303 "Rotate the token $CRED"
python3 -I "$UP/bin/share/release_message.py" "$(git -C "$UP" rev-parse HEAD)" --notes-repo "$UP" \
  --previous-subject "$(git -C "$PUB" log -1 --format=%s main)" > "$T/r3.txt" 2>/dev/null
mkdir -p "$T/r3msg" && cp "$T/r3.txt" "$T/r3msg/COMMIT_MSG.txt"
grep -qF "$CRED" "$T/r3.txt" && ! python3 -I "$DIR/bin/share/leakcheck.py" "$T/r3msg" >/dev/null 2>&1 && ok \
  || bad "R3 the notes message with a credential shape must be refused by leakcheck as a whole"
rc=$(pub)
MSG=$(git -C "$PUB" log -1 --format=%B main)
if [ "$rc" = 0 ] && grep -q 'refused the release notes' "$T/last.out" \
   && [ "$(git -C "$PUB" rev-parse 'main^')" = "$H2" ] \
   && [ "$(sed -n '3,$p' <<<"$MSG")" = "- release notes unavailable for this build" ] \
   && ! grep -qF "$CRED" <<<"$MSG" && ! grep -qF "$CRED" "$T/last.out"; then ok
else bad "R3 a credential in the notes must publish with the fallback bullet, never the credential (rc=$rc): $(tr '\n' '|' <<<"$MSG") $(show)"; fi
H3=$(git -C "$PUB" rev-parse main)

# R3b a credential in the summary is not the notes: the retry refuses too, nothing pushed
echo "more" >> "$UP/content.txt"; gc -C "$UP" commit -qam "upstream more"
rc=$(pub --summary "token $CRED")
if [ "$rc" = 1 ] && grep -q 'leak guard found identifiers in the release message' "$T/last.out" \
   && [ "$(git -C "$PUB" rev-parse main)" = "$H3" ]; then ok
else bad "R3b a credential in the summary must refuse rc 1 and push nothing (rc=$rc): $(show)"; fi

echo "share-release-notes.bh-7185-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
