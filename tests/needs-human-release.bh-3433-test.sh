#!/bin/bash
# tests/needs-human-release.bh-3433-test.sh — the needs-human release slice
# (BH-3446, order 5 of BH-3433). Once a person clears a NEEDS-HUMAN: hold on the
# issue, the next build's review prompt and PR body carry that person's evidence.
#   E1-E12  nh_release_evidence against a REST-shaped thread served by a stub
#   N1-N2   REVIEW_PROMPT, cut from the flattened pipeline with the seam block
#   P1-P2   the PR body built through pr.sh's evidence block
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
export HARNESS_TEST_SANDBOX=1
. "$DIR/tests/lib/rb-all.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

LIB="$DIR/bin/lib/needs-human.sh"
RELEASE="$DIR/bin/lib/needs-human/release.sh"
[ -r "$RELEASE" ] && ok || bad "D41: $RELEASE is missing"
SENTENCE='A person ran the human step; their evidence is below. Do not re-block on that finding; check the PR body quotes it.'

# The thread: one JSON comment per line in $T/thread.jsonl, served 100 a page.
# gh_rest (PATH) answers the page body and exits with $T/rc; gh (PATH) answers
# the same page as an HTTP response, for the real gh-rest.sh in P1/P2. Every
# call is recorded to $T/calls.
mkdir -p "$T/bin"
cat > "$T/bin/serve" <<EOF
#!/bin/bash
echo "\$*" >> "$T/calls"
p=\$(sed -nE 's/.*[?&]page=([0-9]+).*/\1/p' <<<"\$*")
f="$T/page\${p:-1}.json"; [ -r "\$f" ] || echo '[]' > "\$f"
EOF
cat > "$T/bin/gh_rest" <<EOF
#!/bin/bash
. "$T/bin/serve"
cat "\$f"; exit "\$(cat "$T/rc" 2>/dev/null || echo 0)"
EOF
cat > "$T/bin/gh" <<EOF
#!/bin/bash
. "$T/bin/serve"
printf 'HTTP/2.0 200 OK\r\ncontent-type: application/json\r\n\r\n'; cat "\$f"
EOF
for s in alert-line jobs; do
  printf '#!/bin/bash\n: > "%s/called.%s"\nexit 0\n' "$T" "$s" > "$T/bin/$s"
done
chmod +x "$T/bin/"*
export PATH="$T/bin:$PATH"

N=0
reset() { : > "$T/thread.jsonl"; rm -f "$T"/page*.json "$T/calls" "$T/rc"; N=0; }
c() { # c <login> <User|Bot> <created_at> <body>
  N=$((N+1))
  jq -nc --arg l "$1" --arg t "$2" --arg c "$3" --arg b "$4" --argjson n "$N" \
    '{id:$n, html_url:("https://github.com/o/r/issues/7#issuecomment-" + ($n|tostring)), user:{login:$l, type:$t}, created_at:$c, body:$b}' \
    >> "$T/thread.jsonl"
}
serve() { # split the thread into 100-comment pages
  local i=0
  rm -f "$T"/page*.json
  split -l 100 -d -a 3 "$T/thread.jsonl" "$T/chunk." 2>/dev/null
  for f in "$T"/chunk.*; do [ -e "$f" ] || continue; i=$((i+1)); jq -sc . "$f" > "$T/page$i.json"; rm -f "$f"; done
  [ "$i" = 0 ] && echo '[]' > "$T/page1.json"
  return 0
}
URL() { echo "https://github.com/o/r/issues/7#issuecomment-$1"; }
MARK='NEEDS-HUMAN: set FOO in Vercel prod <!-- nh-fp:abcdef123456 -->'

# shellcheck disable=SC1090
. "$LIB"
EV() { OUT=$(nh_release_evidence o/r 7); RC=$?; }

# ── E: nh_release_evidence ─────────────────────────────────────────────────
# E1: a Bot marker counts; a human release after it, across two pages.
reset
for i in $(seq 1 100); do c someone User "2026-09-01T00:00:00Z" "noise $i"; done
c harness-bot Bot "2026-09-29T10:00:00Z" "$MARK"
c operator User "2026-09-29T11:00:00Z" $'HUMAN-STEP-DONE: set FOO in Vercel prod\nchecked the preview too'
c someone User "2026-09-29T11:30:00Z" "thanks"
serve; EV
[ "$RC" = 0 ] && [ "$(sed -n 1p <<<"$OUT")" = "comment: $(URL 102)" ] && ok || bad "E1: rc $RC first line '$(sed -n 1p <<<"$OUT")'"
grep -qx 'author: @operator at 2026-09-29T11:00:00Z' <<<"$OUT" && grep -qx 'HUMAN-STEP-DONE: set FOO in Vercel prod' <<<"$OUT" \
  && grep -qx 'checked the preview too' <<<"$OUT" && ok || bad "E1: author/body missing: $OUT"
[ "$(grep -c 'page=' "$T/calls" 2>/dev/null)" = 2 ] && grep -q 'repos/o/r/issues/7/comments?per_page=100&page=2' "$T/calls" \
  && ok || bad "E1: expected two paged reads: $(cat "$T/calls" 2>/dev/null)"

# E2: the Hub probe PASS shape.
reset
c harness-bot Bot "2026-09-29T10:00:00Z" "$MARK"
c operator User "2026-09-29T11:00:00Z" $'## Hub probe vs_publish PASS\nstatus 200'
serve; EV
[ "$RC" = 0 ] && [ "$(sed -n 1p <<<"$OUT")" = "comment: $(URL 2)" ] && grep -qx 'status 200' <<<"$OUT" \
  && ok || bad "E2: hub probe PASS not evidence: rc $RC '$OUT'"
# E2b: both shapes after the marker — the newer wins, whatever the page order.
reset
c harness-bot Bot "2026-09-29T10:00:00Z" "$MARK"
c operator User "2026-09-29T12:00:00Z" '## Hub probe vs_publish PASS'
c operator User "2026-09-29T11:00:00Z" 'HUMAN-STEP-DONE: set FOO'
serve; EV
[ "$(sed -n 1p <<<"$OUT")" = "comment: $(URL 2)" ] && ok || bad "E2b: the newer release did not win: '$OUT'"
# Same second: the REST index breaks the tie.
reset
c harness-bot Bot "2026-09-29T10:00:00Z" "$MARK"
c operator User "2026-09-29T11:00:00Z" 'HUMAN-STEP-DONE: first'
c operator User "2026-09-29T11:00:00Z" 'HUMAN-STEP-DONE: second'
serve; EV
[ "$(sed -n 1p <<<"$OUT")" = "comment: $(URL 3)" ] && ok || bad "E2b: same-second tie not broken by index: '$OUT'"

none() { # none <label> — the thread served now yields no evidence, rc 0
  serve; EV
  [ -z "$OUT" ] && [ "$RC" = 0 ] && ok || bad "$1: gave rc $RC '$OUT'"
}
# E3: a Bot release does not count.
reset; c harness-bot Bot "2026-09-29T10:00:00Z" "$MARK"; c harness-bot Bot "2026-09-29T11:00:00Z" 'HUMAN-STEP-DONE: ok'; none E3
# E4: a human release older than the marker.
reset; c operator User "2026-09-29T09:00:00Z" 'HUMAN-STEP-DONE: done early'; c harness-bot Bot "2026-09-29T10:00:00Z" "$MARK"; none E4
# E5: the "do not post it yet" shape.
reset; c harness-bot Bot "2026-09-29T10:00:00Z" "$MARK"; c operator User "2026-09-29T11:00:00Z" 'Do NOT post HUMAN-STEP-DONE yet, the migration is still pending'; none E5
# E6: Hub probe FAIL, and E6b a mixed PASS/FAIL header.
reset; c harness-bot Bot "2026-09-29T10:00:00Z" "$MARK"; c operator User "2026-09-29T11:00:00Z" '## Hub probe results FAIL'; none E6
reset; c harness-bot Bot "2026-09-29T10:00:00Z" "$MARK"; c operator User "2026-09-29T11:00:00Z" '## Hub probe: 3 PASS, 1 FAIL'; none E6b
# E6c: mid-body, quoted, lowercase.
reset; c harness-bot Bot "2026-09-29T10:00:00Z" "$MARK"; c operator User "2026-09-29T11:00:00Z" $'I think we are close.\n\nHUMAN-STEP-DONE: x'; none E6c-midbody
reset; c harness-bot Bot "2026-09-29T10:00:00Z" "$MARK"; c operator User "2026-09-29T11:00:00Z" '> HUMAN-STEP-DONE: quoted'; none E6c-quoted
reset; c harness-bot Bot "2026-09-29T10:00:00Z" "$MARK"; c operator User "2026-09-29T11:00:00Z" 'human-step-done: lower'; none E6c-lowercase
# A marker that is only mentioned mid-body is not a hold.
reset; c operator User "2026-09-29T10:00:00Z" $'about the protocol:\nNEEDS-HUMAN: x'; c operator User "2026-09-29T11:00:00Z" 'HUMAN-STEP-DONE: x'; none E6c-midbody-marker
# The positive counterparts of E6c, so the negatives above are not vacuous:
# leading blank lines, CRLF and indentation are normalised on the first line.
reset; c harness-bot Bot "2026-09-29T10:00:00Z" "$MARK"; c operator User "2026-09-29T11:00:00Z" $'\r\n\n   HUMAN-STEP-DONE: done\r\nline two\r'
serve; EV
[ "$(sed -n 1p <<<"$OUT")" = "comment: $(URL 2)" ] && ! grep -q $'\r' <<<"$OUT" && ok || bad "E6c: CRLF/leading-blank release not recognised or CR kept: '$OUT'"

# E7: gh_rest non-zero → nothing, rc 2. E8: a non-array page → nothing, rc 2.
reset; c harness-bot Bot "2026-09-29T10:00:00Z" "$MARK"; c operator User "2026-09-29T11:00:00Z" 'HUMAN-STEP-DONE: x'; serve
echo 75 > "$T/rc"; EV
[ -z "$OUT" ] && [ "$RC" = 2 ] && ok || bad "E7: gh_rest rc 75 gave rc $RC '$OUT'"
rm -f "$T/rc"; echo '{"message":"Not Found"}' > "$T/page1.json"; EV
[ -z "$OUT" ] && [ "$RC" = 2 ] && ok || bad "E8: non-array page gave rc $RC '$OUT'"
# A release on page 1 with page 2 unreadable is still unreadable, never evidence.
reset; c harness-bot Bot "2026-09-29T10:00:00Z" "$MARK"
for i in $(seq 1 99); do c operator User "2026-09-29T11:00:00Z" 'HUMAN-STEP-DONE: x'; done
serve; echo 'not json' > "$T/page2.json"; EV
[ -z "$OUT" ] && [ "$RC" = 2 ] && ok || bad "E8: unparseable page 2 gave rc $RC '$(head -1 <<<"$OUT")'"
# No gh_rest anywhere → rc 2.
OUT=$(PATH=/usr/bin:/bin; unset -f gh_rest 2>/dev/null; nh_release_evidence o/r 7); RC=$?
[ -z "$OUT" ] && [ "$RC" = 2 ] && ok || bad "E8: no gh_rest gave rc $RC '$OUT'"

# E9: a release between two markers belongs to the old hold.
reset
c harness-bot Bot "2026-09-29T10:00:00Z" "$MARK"
c operator User "2026-09-29T11:00:00Z" 'HUMAN-STEP-DONE: first hold'
c harness-bot Bot "2026-09-29T12:00:00Z" "$MARK"
none E9
# A non-ISO created_at sorts oldest: it is never newer than a dated marker.
reset; c harness-bot Bot "2026-09-29T10:00:00Z" "$MARK"; c operator User "yesterday" 'HUMAN-STEP-DONE: x'; none E9-non-iso

# E10: more than 1000 comments → rc 2.
reset
for i in $(seq 1 10); do jq -nc '[range(100)|{id:., user:{login:"a",type:"User"}, created_at:"2026-09-01T00:00:00Z", body:"x", html_url:"u"}]' > "$T/page$i.json"; done
EV
[ -z "$OUT" ] && [ "$RC" = 2 ] && ok || bad "E10: 1000+ comments gave rc $RC"
# E11: a 41-line body → exactly 40 body lines.
reset; c harness-bot Bot "2026-09-29T10:00:00Z" "$MARK"
c operator User "2026-09-29T11:00:00Z" "$(printf 'HUMAN-STEP-DONE: long\n'; seq 2 41 | sed 's/^/line /')"
serve; EV
[ "$(wc -l <<<"$OUT")" = 42 ] && grep -qx 'line 40' <<<"$OUT" && ! grep -qx 'line 41' <<<"$OUT" \
  && ok || bad "E11: expected 2 header + 40 body lines, got $(wc -l <<<"$OUT")"
# E12: a bad slug / issue → rc 2 and no read at all.
reset
for A in "|7" "o/r|abc" "o/r|" "nosl|7"; do
  OUT=$(nh_release_evidence "${A%%|*}" "${A#*|}"); RC=$?
  [ -z "$OUT" ] && [ "$RC" = 2 ] && [ ! -e "$T/calls" ] && ok || bad "E12: '$A' gave rc $RC, calls: $(cat "$T/calls" 2>/dev/null)"
done
# E12: a release with no marker anywhere in the thread releases nothing.
reset; c operator User "2026-09-29T11:00:00Z" 'HUMAN-STEP-DONE: stray'; none E12-no-marker

# ── N: REVIEW_PROMPT, cut from the flattened pipeline ──────────────────────
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh")
cut_block() { awk -v n="$1" 'index($0,"# >>> " n)==1{f=1;next} index($0,"# <<< " n)==1{exit} f' "$RB_ALL" > "$2"; }
cut_block "needs-human seam" "$T/seam.sh"
# TEST-CHANGE (BH-7970): REVIEW_PROMPT is now built by the `review prompt` block (SP_REVIEW_* precompute + sp_render of
# prompts/stages/review.md); the driver runs that real block with the repo lib bin/lib/stage-prompt.sh sourced first.
cut_block "review prompt" "$T/prompt.sh"
[ -s "$T/seam.sh" ] && grep -q 'nh_prompt_release_note' "$T/prompt.sh" && ok || bad "N: could not cut the seam / REVIEW_PROMPT"
mkdir -p "$T/s/bin/lib/needs-human" "$T/s/repo"
cp "$LIB" "$T/s/bin/lib/"; cp "$DIR"/bin/lib/needs-human/*.sh "$T/s/bin/lib/needs-human/"
printf '#!/bin/bash\n[ "${2:-}" = board_prefix ] && cat "%s/prefix"\n' "$T" > "$T/s/bin/fleet-conf.sh"; chmod +x "$T/s/bin/fleet-conf.sh"
git -C "$T/s/repo" init -q && git -C "$T/s/repo" remote add origin https://github.com/o/r.git
PROMPT() { # PROMPT <board prefix> — the prompt a review round on BH-7 builds
  echo "$1" > "$T/prefix"
  (cd "$T/s/repo" && HARNESS="$T/s" PROJECT=p KEY=BH-7 bash -c '. "$3"; . "$1"; . "$2"; printf "%s" "$REVIEW_PROMPT"' _ "$T/seam.sh" "$T/prompt.sh" "$DIR/bin/lib/stage-prompt.sh" 2>"$T/prompt.err")
}
reset; c harness-bot Bot "2026-09-29T10:00:00Z" "$MARK"; c operator User "2026-09-29T11:00:00Z" 'HUMAN-STEP-DONE: set FOO in Vercel prod'; serve
OUT=$(PROMPT -)
grep -qF "$SENTENCE" <<<"$OUT" && grep -qx "comment: $(URL 2)" <<<"$OUT" && grep -qx 'HUMAN-STEP-DONE: set FOO in Vercel prod' <<<"$OUT" \
  && ok || bad "N1: the release note is not in REVIEW_PROMPT: $(tail -c 300 <<<"$OUT") $(cat "$T/prompt.err")"
[ "$(tail -c 22 <<<"$OUT" | head -c 21)" != "VERDICT: APPROVE or V" ] && ok || bad "N1: the prompt did not grow"
# N2: no evidence → neither the sentence nor a comment line, and the prompt ends where it did.
# "Where it did" is the verdict line plus the BH-3444 field note (nh_prompt_field_note,
# spliced before this slice's release note; empty while it was a stub), exactly.
PEND="VERDICT: APPROVE or VERDICT: BLOCK.$(nh_prompt_field_note 2>/dev/null)"
reset; c harness-bot Bot "2026-09-29T10:00:00Z" "$MARK"; serve
OUT=$(PROMPT -)
! grep -qF "$SENTENCE" <<<"$OUT" && ! grep -q '^comment: ' <<<"$OUT" && [[ "$OUT" == *"$PEND" ]] \
  && ok || bad "N2: a no-evidence thread changed the prompt: $(tail -3 <<<"$OUT")"
# N2: a board project (no issue) reads nothing, even with evidence on the thread.
reset; c harness-bot Bot "2026-09-29T10:00:00Z" "$MARK"; c operator User "2026-09-29T11:00:00Z" 'HUMAN-STEP-DONE: x'; serve
OUT=$(PROMPT FR)
[[ "$OUT" == *"$PEND" ]] && [ ! -e "$T/calls" ] && ok || bad "N2: a board project read the thread or grew the prompt"

# ── P: the PR body, via pr.sh's evidence block ─────────────────────────────
cut_block "evidence block" "$T/block.sh"
cut_block "merge note fn" "$T/mergenote.sh"
[ -s "$T/block.sh" ] && [ -s "$T/mergenote.sh" ] && ok || bad "P: could not extract the evidence block"
mkdir -p "$T/p/bin/lib/needs-human" "$T/p/build" "$T/p/repo"
cp "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$LIB" "$T/p/bin/lib/"
cp "$DIR"/bin/lib/needs-human/*.sh "$T/p/bin/lib/needs-human/"
cp "$T/s/bin/fleet-conf.sh" "$T/p/bin/"
# BH-7919: the Closes line (bin/lib/rb/pr.sh) now asks bin/lib/tracker.sh trk_gh_issue_number.
scratch_install_closure bin/lib/tracker.sh "$T/p" >/dev/null || exit 1
( cd "$T/p/repo" && git init -q -b main && git config user.email t@example.com && git config user.name t \
  && git remote add origin https://github.com/o/r.git \
  && echo one > a.txt && git add -A && git -c commit.gpgsign=false commit -qm "TK-269: the subject" ) >/dev/null 2>&1
PBODY() { # PBODY <out> [pre-eval] — gh_rest is the REAL lib, over the gh stub
  echo "-" > "$T/prefix"
  ( cd "$T/p/repo" || exit 1
    env HARNESS="$T/p" BUILD="$T/p/build" KEY=TK-7 PRE="${2:-}" bash -c '
      set -uo pipefail
      STAMP() { echo TS; }
      PROJECT=ts; SLUG=o/r; BASE=main; TIER=1; QA_NOTE=""; MIG_NOTE=""; ADDED_SQL=""; E2E_VERDICT=pass
      CHANGED="a.txt"; TAMPER_RC=0; REPRO_RC=0; INTENT_RC=0
      WHAT_LIST="- did a thing"; WHY_EXCERPT="because"; VERIFY_LINE="v"; SPEC_LINE="s"
      PLAN_MODEL=pm; EXECUTE_MODEL=em; REVIEW_MODEL=rm; MIG_SECTION=""; COST_LINE="c"
      CTX_SIG=sig; CTX_COMMIT=abc; CTX_SYNC=yes; CTX_FRESH=yes
      job_evidence_put() { return 0; }
      . "$HARNESS/bin/lib/gh-rest.sh"
      eval "$PRE"
      . "$0"; . "$1"
      printf "%s" "$(PR_BODY_FOR "$EVIDENCE_SECTION")" > "$2"
    ' "$T/mergenote.sh" "$T/block.sh" "$1" 2>"$1.err" )
}
reset; c harness-bot Bot "2026-09-29T10:00:00Z" "$MARK"
c operator User "2026-09-29T11:00:00Z" $'HUMAN-STEP-DONE: set FOO in Vercel prod\n\n## Not a section'; serve
PBODY "$T/body.ev"
grep -qx '## Human step evidence' "$T/body.ev" && grep -qx '> HUMAN-STEP-DONE: set FOO in Vercel prod' "$T/body.ev" \
  && grep -qF "$(URL 2)" "$T/body.ev" && ok || bad "P1: no quoted evidence in the PR body: $(cat "$T/body.ev.err"; grep -n 'Human\|HUMAN' "$T/body.ev")"
grep -qx '> ## Not a section' "$T/body.ev" && ! grep -qx '## Not a section' "$T/body.ev" && grep -qx '>' "$T/body.ev" \
  && ok || bad "P1: evidence lines escaped the blockquote"
grep -q 'repos/o/r/issues/7/comments' "$T/calls" 2>/dev/null && ok || bad "P1: the real gh_rest never read the thread"
# P2: a no-evidence thread → cmp-identical to a body with no release section at all.
reset; c harness-bot Bot "2026-09-29T10:00:00Z" "$MARK"; serve
PBODY "$T/body.none"
PBODY "$T/body.unset" '. "$HARNESS/bin/lib/needs-human.sh"; unset -f nh_pr_body_section'
[ -s "$T/body.none" ] && grep -q '^Closes #7$' "$T/body.none" && cmp -s "$T/body.none" "$T/body.unset" \
  && ok || bad "P2: a no-evidence thread changed the PR body: $(diff "$T/body.none" "$T/body.unset" | head -5)"

[ -z "$(find "$T" -maxdepth 1 -name 'called.*')" ] && ok || bad "no alert/jobs stub may be called: $(ls "$T"/called.* 2>/dev/null)"

echo "needs-human-release: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
