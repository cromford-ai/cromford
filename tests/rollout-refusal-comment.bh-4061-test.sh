#!/bin/bash
# tests/rollout-refusal-comment.bh-4061-test.sh — BH-4061 refusal half.
#
# A rollout the parser refused used to write `ROLLOUT_FAILED <reason>` into the
# build dir and nothing else: the author never saw the reason, and the master
# kept its `ai-build` label, so every tick rebuilt it into the same refusal.
# bin/lib/rollout-refusal.sh now posts ONE comment per (issue, reason), carrying
# a hidden marker it finds again on the next tick, and parks the master.
#
# Drives a copy of the real bin/run-rollout.sh with the real file-children,
# fc-issues, gh-rest and rollout-refusal libraries beside it, NOT dry-run,
# against a gh stub that keeps the issue's comments on disk and logs every call.
#
#   R1  a refusal posts 1 comment (marker, reason, ai-build) and removes ai-build
#   R2  the same refusal on the next tick posts nothing
#   R3  a different refusal posts a new comment with a new marker
#   R4  a failed unlabel is retried next tick without a second comment
#   R5  an infra failure (body fetch) posts nothing and parks nothing
#   R6  an unreadable comment list posts nothing, parks nothing, logs UNKNOWN
#   R7  dry run writes the comment file and the gh lines, and calls nothing
#   R8  a tree without the lib behaves as before (RESULT only)
#   R9  a comment that did not post never leads to an unlabel
#   R10 a resumed run (waves already on the record) never says "we did not file"
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "jq missing — skipping"; exit 0; }

mkdir -p "$T/h/bin" "$T/co/bin/lib" "$T/bodies"
cp "$DIR/bin/fleet-conf.sh" "$T/h/bin/"
cp "$DIR/bin/run-rollout.sh" "$DIR/bin/fleet-conf.sh" "$T/co/bin/"
cp "$DIR/bin/lib/file-children.sh" "$DIR/bin/lib/fc-issues.sh" "$DIR/bin/lib/gh-rest.sh" \
   "$DIR/bin/lib/rollout-refusal.sh" "$DIR/bin/lib/tracker.sh" "$T/co/bin/lib/"
mkdir -p "$T/co/bin/lib/tracker" && cp "$DIR/bin/lib/tracker/github-issues.sh" "$T/co/bin/lib/tracker/"
chmod +x "$T/co/bin/run-rollout.sh"
# R8's tree: the same scripts with no refusal lib.
mkdir -p "$T/old/bin/lib"
cp "$DIR/bin/run-rollout.sh" "$DIR/bin/fleet-conf.sh" "$T/old/bin/"
cp "$DIR/bin/lib/file-children.sh" "$DIR/bin/lib/fc-issues.sh" "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/tracker.sh" "$T/old/bin/lib/"
mkdir -p "$T/old/bin/lib/tracker" && cp "$DIR/bin/lib/tracker/github-issues.sh" "$T/old/bin/lib/tracker/"
chmod +x "$T/old/bin/run-rollout.sh"
cat > "$T/h/fleet.conf" <<'CONF'
scoutish example-org/scoutish https://scoutish.example - 9 box-1 10.0.0.9
CONF

# The gh stub. `issue view` answers the body (or fails when $T/fail-body
# exists). `api -i` is the REST path gh_rest uses: the comments list is served
# from $T/comments.json (status from $T/st-comments), a POST appends to it, a
# DELETE of the label answers $T/st-delete once (then 200). Every call is
# logged to $T/calls as "<METHOD> <path>".
cat > "$T/h/bin/gh" <<'SH'
#!/bin/bash
if [ "$1" = issue ] && [ "$2" = view ]; then
  [ -e "$GHT/fail-body" ] && { echo "HTTP 502" >&2; exit 1; }
  cat "$GH_BODY"; exit 0
fi
send() { printf 'HTTP/2 %s\r\nserver: x\r\n\r\n%s' "$1" "${2:-}"; exit 0; }
if [ "$1" = api ] && [ "$2" = -i ]; then
  m="$4"; p="$5"; shift 5
  echo "$m $p" >> "$GHT/calls"
  [ -s "$GHT/comments.json" ] || echo '[]' > "$GHT/comments.json"
  case "$m $p" in
    "GET repos/"*"/comments?"*)
      st=$(cat "$GHT/st-comments" 2>/dev/null || echo 200)
      [ "$st" = 200 ] || send "$st" '{"message":"bad gateway"}'
      case "$p" in *"page=1") send 200 "$(cat "$GHT/comments.json")" ;; *) send 200 '[]' ;; esac ;;
    "POST repos/"*"/comments")
      [ -e "$GHT/st-post" ] && send "$(cat "$GHT/st-post")" '{"message":"server error"}'
      f=""; while [ $# -gt 0 ]; do case "$1" in -F) f="${2#body=@}"; shift ;; esac; shift; done
      jq --rawfile b "$f" '. + [{body:$b}]' "$GHT/comments.json" > "$GHT/c.tmp" && mv "$GHT/c.tmp" "$GHT/comments.json"
      send 201 '{"id":1}' ;;
    "DELETE repos/"*"/labels/ai-build")
      if [ -e "$GHT/st-delete" ]; then st=$(cat "$GHT/st-delete"); rm -f "$GHT/st-delete"; send "$st" '{}'; fi
      send 200 '[]' ;;
  esac
  send 404 '{}'
fi
echo "gh stub: $*" >&2; exit 1
SH
chmod +x "$T/h/bin/gh"

# drive <body-file> [tree] — a fresh build dir $T/b, NOT dry-run, issue #7.
drive() {
  scratch_rm "$T/b" 2>/dev/null; mkdir -p "$T/b"
  ( env HARNESS="$T/h" FLEET_CONF="$T/h/fleet.conf" PATH="$T/h/bin:$PATH" GHT="$T" \
      GH_BODY="$1" "${2:-$T/co}/bin/run-rollout.sh" scoutish 7 BH-7 "$T/b" >"$T/b/stdout.txt" 2>&1 )
}
drive_env() { # drive_env <body-file> <VAR=val>... — the same, with extra env
  local body="$1"; shift
  scratch_rm "$T/b" 2>/dev/null; mkdir -p "$T/b"
  ( env HARNESS="$T/h" FLEET_CONF="$T/h/fleet.conf" PATH="$T/h/bin:$PATH" GHT="$T" \
      GH_BODY="$body" "$@" "$T/co/bin/run-rollout.sh" scoutish 7 BH-7 "$T/b" >"$T/b/stdout.txt" 2>&1 )
}
# count <ERE> — calls matching it; 0 when nothing was called at all.
count()   { local c; c=$(grep -cE "$1" "$T/calls" 2>/dev/null); printf '%s' "${c:-0}"; }
posts()   { count '^POST repos/example-org/scoutish/issues/7/comments$'; }
deletes() { count '^DELETE repos/example-org/scoutish/issues/7/labels/ai-build$'; }
reads()   { count '^GET repos/example-org/scoutish/issues/7/comments'; }
markers() { jq -r '.[].body' "$T/comments.json" 2>/dev/null | grep -o '<!-- rollout-refusal:[0-9a-f]* -->' ; }
last_result() { grep '^RESULT ' "$T/b/rollout-run.txt" 2>/dev/null | tail -1; }
reset() { rm -f "$T/calls" "$T/comments.json" "$T/st-comments" "$T/st-delete" "$T/st-post" "$T/fail-body"; }

printf '## Rollout\n### Wave: a\nOne.\n### Wave: b\nafter: x\nTwo.\n' > "$T/bodies/unknown.md"
printf '## Rollout\n### Wave: a, b\nOne.\n### Wave: c\nafter: a\nTwo.\n' > "$T/bodies/comma.md"
UNKNOWN_REASON='unknown dependency "x" (known: "a", "b")'

# ── R1: one comment, the marker, the reason, the label off ────────────────
reset
drive "$T/bodies/unknown.md"
[ "$(posts)" = 1 ] && ok || bad "R1: want 1 POST, got $(posts): $(cat "$T/calls" 2>/dev/null)"
[ "$(deletes)" = 1 ] && ok || bad "R1: want 1 DELETE, got $(deletes)"
[ "$(markers | wc -l)" = 1 ] && ok || bad "R1: want 1 marker on the thread"
BODY=$(jq -r '.[0].body' "$T/comments.json" 2>/dev/null)
[ "$(head -1 <<<"$BODY")" = "$(markers | head -1)" ] && ok || bad "R1: the marker is not the first line"
grep -qF "$UNKNOWN_REASON" <<<"$BODY" && ok || bad "R1: reason not quoted verbatim: $BODY"
grep -qF 'ai-build' <<<"$BODY" && ok || bad "R1: no ai-build instruction"
grep -q 'after:' <<<"$BODY" && ok || bad "R1: no fix line for an unknown dependency"
grep -q '—' <<<"$BODY" && bad "R1: an em dash in client copy" || ok
[ "$(last_result)" = "RESULT \"ROLLOUT_FAILED $UNKNOWN_REASON\"" ] && ok || bad "R1: RESULT changed: $(last_result)"
grep -q '^RESULT' "$T/b/stdout.txt" && bad "R1: notify printed a RESULT-shaped line on stdout" || ok
M1=$(markers | head -1)

# ── R2: the next tick, same reason, finds its own comment ─────────────────
rm -f "$T/calls"
drive "$T/bodies/unknown.md"
[ "$(posts)" = 0 ] && ok || bad "R2: reposted ($(posts) POSTs)"
[ "$(reads)" -ge 1 ] && ok || bad "R2: never read the thread"
[ "$(markers | wc -l)" = 1 ] && ok || bad "R2: thread holds $(markers | wc -l) markers"

# ── R3: a new reason gets a new comment ───────────────────────────────────
rm -f "$T/calls"
drive "$T/bodies/comma.md"
[ "$(posts)" = 1 ] && ok || bad "R3: want 1 POST, got $(posts)"
[ "$(markers | sort -u | wc -l)" = 2 ] && ok || bad "R3: want 2 distinct markers"
jq -r '.[1].body' "$T/comments.json" | grep -qF 'comma in wave title' && ok || bad "R3: reason missing"
[ "$(markers | tail -1)" != "$M1" ] && ok || bad "R3: same marker reused"

# ── R4: a failed unlabel is retried, the comment is not ───────────────────
reset
echo 500 > "$T/st-delete"
drive "$T/bodies/unknown.md"
[ "$(posts)" = 1 ] && ok || bad "R4: want 1 POST, got $(posts)"
grep -q 'WARN.*ai-build' "$T/b/pipeline.log" && ok || bad "R4: no WARN for the failed unlabel: $(cat "$T/b/pipeline.log")"
rm -f "$T/calls"
drive "$T/bodies/unknown.md"
[ "$(posts)" = 0 ] && ok || bad "R4: second tick reposted"
[ "$(deletes)" = 1 ] && ok || bad "R4: second tick did not retry the unlabel"

# ── R5: an infra failure is not the author's to fix ───────────────────────
reset
: > "$T/fail-body"
drive "$T/bodies/unknown.md"
[ "$(last_result)" = 'RESULT "ROLLOUT_FAILED body fetch failed"' ] && ok || bad "R5: result $(last_result)"
[ "$(reads)" = 0 ] && [ "$(posts)" = 0 ] && [ "$(deletes)" = 0 ] && ok || bad "R5: touched the thread: $(cat "$T/calls" 2>/dev/null)"

# ── R6: an unreadable thread is UNKNOWN, never "no marker" ────────────────
reset
echo 502 > "$T/st-comments"
drive "$T/bodies/unknown.md"
[ "$(posts)" = 0 ] && ok || bad "R6: posted with an unreadable thread"
[ "$(deletes)" = 0 ] && ok || bad "R6: parked with an unreadable thread"
grep -q 'ROLLOUT_REFUSAL_UNKNOWN' "$T/b/pipeline.log" && ok || bad "R6: no UNKNOWN line: $(cat "$T/b/pipeline.log")"
[ "$(last_result)" = "RESULT \"ROLLOUT_FAILED $UNKNOWN_REASON\"" ] && ok || bad "R6: RESULT changed: $(last_result)"
# A thread with exactly 1000 comments (10 full pages) cannot be proven clean either.
reset
jq -n '[range(100)|{body:"x"}]' > "$T/comments.json"
sed -i 's|case "$p" in \*"page=1")|case "$p" in *"page="*)|' "$T/h/bin/gh"
drive "$T/bodies/unknown.md"
[ "$(reads)" = 10 ] && ok || bad "R6b: want 10 page reads, got $(reads)"
[ "$(posts)" = 0 ] && [ "$(deletes)" = 0 ] && ok || bad "R6b: acted on a thread it could not read to the end"
grep -q 'ROLLOUT_REFUSAL_UNKNOWN' "$T/b/pipeline.log" && ok || bad "R6b: no UNKNOWN line"
sed -i 's|case "$p" in \*"page="\*)|case "$p" in *"page=1")|' "$T/h/bin/gh"

# ── R7: dry run calls nothing and leaves the commands to read ─────────────
reset
drive_env "$T/bodies/unknown.md" DECOMPOSE_DRY_RUN=1
[ ! -s "$T/calls" ] && ok || bad "R7: dry run reached gh: $(cat "$T/calls")"
grep -qF "$UNKNOWN_REASON" "$T/b/rollout-refusal-comment.md" 2>/dev/null && ok || bad "R7: no comment file"
grep -q 'POST repos/example-org/scoutish/issues/7/comments' "$T/b/decompose-gh.log" 2>/dev/null \
  && grep -q 'DELETE repos/example-org/scoutish/issues/7/labels/ai-build' "$T/b/decompose-gh.log" \
  && ok || bad "R7: gh lines missing from decompose-gh.log"

# ── R8: no lib in the tree, nothing changes ───────────────────────────────
reset
drive "$T/bodies/unknown.md" "$T/old"
[ ! -s "$T/calls" ] && ok || bad "R8: a lib-less tree touched the thread"
[ "$(last_result)" = "RESULT \"ROLLOUT_FAILED $UNKNOWN_REASON\"" ] && ok || bad "R8: result $(last_result)"

# ── R9: a failed post leaves the label on, so the next tick retries ──────
reset
echo 500 > "$T/st-post"
drive "$T/bodies/unknown.md"
[ "$(posts)" = 1 ] && ok || bad "R9: want 1 POST attempt, got $(posts)"
[ "$(deletes)" = 0 ] && ok || bad "R9: unlabelled a master whose comment never posted"
grep -q 'WARN.*did not post' "$T/b/pipeline.log" && ok || bad "R9: no WARN: $(cat "$T/b/pipeline.log")"
[ "$(last_result)" = "RESULT \"ROLLOUT_FAILED $UNKNOWN_REASON\"" ] && ok || bad "R9: RESULT changed: $(last_result)"

# ── R10: some waves are already filed; a later refusal must not comment ──
reset
scratch_rm "$T/b" 2>/dev/null; mkdir -p "$T/b"
printf '42\n' > "$T/b/children.txt"
printf '[{"title":"a","body":"","after":[]},{"title":"b","body":"","after":[1]}]\n' > "$T/b/children.json"
( env HARNESS="$T/h" FLEET_CONF="$T/h/fleet.conf" PATH="$T/h/bin:$PATH" GHT="$T" \
    GH_BODY="$T/bodies/unknown.md" "$T/co/bin/run-rollout.sh" scoutish 7 BH-7 "$T/b" >"$T/b/stdout.txt" 2>&1 )
[ "$(last_result)" = "RESULT \"ROLLOUT_FAILED $UNKNOWN_REASON\"" ] && ok || bad "R10: result $(last_result)"
[ "$(posts)" = 0 ] && [ "$(deletes)" = 0 ] && ok || bad "R10: commented on a partly filed rollout: $(cat "$T/calls" 2>/dev/null)"

echo "rollout-refusal-comment: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
