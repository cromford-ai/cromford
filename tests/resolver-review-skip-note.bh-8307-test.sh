#!/bin/bash
# tests/resolver-review-skip-note.bh-8307-test.sh — BH-8307: the resolver says
# why a review that asks for changes started no fix round, and still starts none.
#
# THE INCIDENT. On 2026-10-25 a user posted review 5643798807 on
# project-6#2597: "BLOCK ... VERDICT: REQUEST_CHANGES", no harness footer. The
# resolver skipped it, correctly (a user review never starts a fix round), but
# said nothing, and two sessions waited about 15 minutes for a round.
#
#   P1-P13  the REAL br_rsn_pick (sourced from the fragment, with the real
#           bin/lib/gh-pr-list.sh trust set) on the decision-rule cases.
#   N1-N7   the REAL br_rsn_note with the real bin/lib/comment-mark.sh: the
#           post-then-mark order, a failed post, the dedup, a bad rows file,
#           observe mode, a mark that does not save.
#   E1-E4   the REAL bin/blocked-resolver.sh, whole, against a real git remote:
#           a user review is noted once over two passes and starts no round; a
#           harness-footer review starts its round and is not noted; a second
#           review id gets its own note.
#   N5      BR_OPT_OFF=bh-8307-review-skip-note: the whole lane notes nothing.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/resolver-review-skip-note.bh-8307-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v git >/dev/null || { echo "git missing — skipping"; exit 0; }

BR="$DIR/bin/blocked-resolver.sh"
FRAG="$DIR/bin/blocked-resolver.d/bh-8307-review-skip-note.sh"
FOOTER='_Automated harness review (Fable) of '
NOTE_TAIL='— skipped; request a lead review to start a fix round'

# ============================================================================
# P — br_rsn_pick
# ============================================================================
PH="$T/ph"; mkdir -p "$PH/env" "$PH/logs"
grep -E '^BR_REVIEW_FOOTER=' "$BR" > "$T/footer.sh"
grep -q . "$T/footer.sh" && ok || bad "P0 BR_REVIEW_FOOTER could not be read from the driver"
# PICK <head> <rows-json> — the real picker, the real trust set.
PICK() {
  HARNESS="$PH" bash -c '. "$1/bin/lib/gh-pr-list.sh"; . "$2"; . "$3" || exit 9; br_rsn_pick "$4" "$5"' \
    _ "$DIR" "$T/footer.sh" "$FRAG" "$1" "$2"
}
PICK_RC() { PICK "$@" >/dev/null 2>&1; echo $?; }
H1=1111111111111111111111111111111111111111
H2=2222222222222222222222222222222222222222
ROW() { # ROW <id> <login> <commit> <state> <body> — one br_review_rows row
  jq -nc --argjson i "$1" --arg l "$2" --arg c "$3" --arg s "$4" --arg b "$5" \
    '{l:$l,t:"User",a:"OWNER",c:$c,s:$s,b:$b,id:$i}'
}
ROWS() { jq -sc . ; }
# The project-6#2597 body shape: opens BLOCK, ends with the verdict, no footer.
UBODY='BLOCK — the migration drops a column the reader still selects.

1. db/0042.sql:3 the DROP COLUMN loses data.

VERDICT: REQUEST_CHANGES'
HFOOT() { # HFOOT <verdict> <sha> — the review bin/review-prs.sh posts
  printf 'Two sentences.\n\nTIER: 2\nVERDICT: %s\n\n---\n%s%s. Static review._\n' "$1" "$FOOTER" "$2"
}

# P1 (a): the incident — a user, COMMENTED, VERDICT: REQUEST_CHANGES, no footer.
OUT=$(PICK "$H1" "$(ROW 5643798807 operator-mac "$H1" COMMENTED "$UBODY" | ROWS)"); RC=$?
[ "$RC" = 0 ] && [ "$OUT" = $'5643798807\toperator-mac\tauthor,footer' ] && ok || bad "P1 the incident review must be noted as author,footer (rc $RC): $OUT"
# P2 (b): the operator, no footer. BH-8419: the operator login is a person,
# never a verdict author, so the review is noted as author,footer.
OUT=$(PICK "$H1" "$(ROW 12 operator "$H1" COMMENTED "$UBODY" | ROWS)")
[ "$OUT" = $'12\toperator\tauthor,footer' ] && ok || bad "P2 the operator with no footer must be noted as author,footer: $OUT"
# P3 (c): a user pasting the footer -> author only.
OUT=$(PICK "$H1" "$(ROW 13 mallory "$H1" COMMENTED "$(HFOOT REQUEST_CHANGES "$H1")" | ROWS)")
[ "$OUT" = $'13\tmallory\tauthor' ] && ok || bad "P3 a non-verdict author pasting the footer must be noted as author: $OUT"
# P4 (d): GitHub state CHANGES_REQUESTED, no VERDICT line -> noted.
OUT=$(PICK "$H1" "$(ROW 14 mallory "$H1" CHANGES_REQUESTED 'please rename this' | ROWS)")
[ "$OUT" = $'14\tmallory\tauthor,footer' ] && ok || bad "P4 a CHANGES_REQUESTED state with no VERDICT line must be noted: $OUT"
# P5 (e): the bold form.
OUT=$(PICK "$H1" "$(ROW 15 mallory "$H1" COMMENTED 'Findings.

**VERDICT:** REQUEST_CHANGES' | ROWS)")
[ "$OUT" = $'15\tmallory\tauthor,footer' ] && ok || bad "P5 a **VERDICT:** REQUEST_CHANGES body must be noted: $OUT"
# P6 (f): a real harness verdict is not noted.
# BH-8419: a harness verdict is the App's (BH-8466: or the operator login's
# footer row, a PAT post; see the TEST-CHANGE below).
[ "$(PICK_RC "$H1" "$(ROW 16 'cromford[bot]' "$H1" COMMENTED "$(HFOOT REQUEST_CHANGES "$H1")" | ROWS)")" = 1 ] && ok || bad "P6 a harness verdict must not be noted"
# TEST-CHANGE (BH-8466): this pinned "the operator's footer review is a person's,
# noted as author". A lane on the default PAT posts its review as the operator
# login, so that row is the lane's own now (br_review_harness_pick briefs it) and
# no skip note is posted. The operator with NO footer is still noted (P2).
OUT=$(PICK "$H1" "$(ROW 16 operator "$H1" COMMENTED "$(HFOOT REQUEST_CHANGES "$H1")" | ROWS)"); RC=$?
[ "$RC" = 1 ] && [ -z "$OUT" ] && ok || bad "P6 the operator's footer review is the lane's own PAT post, never noted (rc $RC): $OUT"
[ "$(PICK_RC "$H1" "$(ROW 16 'cromford[bot]' "$H1" COMMENTED "$(HFOOT REQUEST_CHANGES "$H1")" | ROWS)")" = 1 ] && ok || bad "P6 the App's harness verdict must not be noted"
# P7 (g): a user APPROVE is not noted.
[ "$(PICK_RC "$H1" "$(ROW 17 mallory "$H1" COMMENTED 'LGTM
VERDICT: APPROVE' | ROWS)")" = 1 ] && ok || bad "P7 a user APPROVE must not be noted"
# P8 (h): on an older head only.
[ "$(PICK_RC "$H2" "$(ROW 18 mallory "$H1" COMMENTED "$UBODY" | ROWS)")" = 1 ] && ok || bad "P8 a review on an older head must not be noted"
# P9 (i): a newer user comment on the head decides.
R=$( { ROW 19 mallory "$H1" COMMENTED "$UBODY"; ROW 20 mallory "$H1" COMMENTED 'thanks, looking again'; } | ROWS)
[ "$(PICK_RC "$H1" "$R")" = 1 ] && ok || bad "P9 the newest review on the head must decide"
# ...and the reverse order is noted, with the NEWEST id.
R=$( { ROW 20 mallory "$H1" COMMENTED 'thanks, looking again'; ROW 21 mallory "$H1" COMMENTED "$UBODY"; } | ROWS)
[ "$(PICK "$H1" "$R" | cut -f1)" = 21 ] && ok || bad "P9 the newest review id must be the one noted"
# P10 (j): DISMISSED is not noted, and the row behind it is not either.
R=$( { ROW 22 mallory "$H1" COMMENTED 'a plain comment'; ROW 23 mallory "$H1" DISMISSED "$UBODY"; } | ROWS)
[ "$(PICK_RC "$H1" "$R")" = 1 ] && ok || bad "P10 a DISMISSED review must not be noted"
# P11 (k): the lead-review lane's own marker row.
[ "$(PICK_RC "$H1" "$(ROW 24 'cromford[bot]' "$H1" CHANGES_REQUESTED '<!-- lead-review:lr-1 -->
Findings
- [BLOCK needs-human] cfg.sh:1: which vendor tier
VERDICT: BLOCK' | ROWS)")" = 1 ] && ok || bad "P11 a lead-review marker row must not be noted"
# P12 (l): no verdict, or a partial one.
[ "$(PICK_RC "$H1" "$(ROW 25 mallory "$H1" COMMENTED 'no VERDICT: line here' | ROWS)")" = 1 ] && ok || bad "P12 'no VERDICT: line here' must not be noted"
[ "$(PICK_RC "$H1" "$(ROW 26 mallory "$H1" COMMENTED 'VERDICT: REQUEST' | ROWS)")" = 1 ] && ok || bad "P12 a partial VERDICT: REQUEST must not be noted"
# P13 (m): no rows.
[ "$(PICK_RC "$H1" '[]')" = 1 ] && ok || bad "P13 empty rows must not be noted"

# ============================================================================
# N — br_rsn_note
# ============================================================================
NH="$T/nh"; mkdir -p "$NH"
# NOTE <rows-file> <post-rc> — one call; says to $NH/log, posts to $NH/posts.
NOTE() {
  HARNESS="$PH" ST="${NST:-$NH/st}" NHD="$NH" PRC="$2" bash -c '
    . "$1/bin/lib/gh-pr-list.sh"; . "$1/bin/lib/comment-mark.sh"; . "$2"; . "$3" || exit 9
    say() { printf "%s\n" "$*" >> "$NHD/log"; }
    br_pr_comment() { printf "%s|%s\n" "$1" "$2" >> "$NHD/posts"; return "$PRC"; }
    br_rsn_note tproj o/tproj 81 "$4" "$5"' _ "$DIR" "$T/footer.sh" "$FRAG" "$H1" "$1"
}
NRESET() { scratch_rm "$NH"; mkdir -p "$NH"; : > "$NH/log"; : > "$NH/posts"; }
NLINE="tproj/o/tproj#81: review 31 by mac-drain on ${H1:0:12} is not a harness verdict (author,footer) $NOTE_TAIL"
ROW 31 mac-drain "$H1" COMMENTED "$UBODY" | ROWS > "$T/rows31.json"
# N1: the post works -> one line, one post, one mark.
NRESET; NOTE "$T/rows31.json" 0 > "$NH/out"; RC=$?
[ "$RC" = 0 ] && [ ! -s "$NH/out" ] && ok || bad "N1 rc must be 0 with no stdout (rc $RC): $(cat "$NH/out")"
[ "$(cat "$NH/log")" = "$NLINE" ] && ok || bad "N1 the log line: $(cat "$NH/log")"
[ "$(cat "$NH/posts")" = "https://github.com/o/tproj/pull/81|$NLINE" ] && ok || bad "N1 the post: $(cat "$NH/posts")"
[ -e "$NH/st/review-skip/o_tproj-81-31" ] && ok || bad "N1 the mark was not written"
# N3: the mark is there -> no post, no line.
: > "$NH/log"; : > "$NH/posts"; NOTE "$T/rows31.json" 0
[ ! -s "$NH/log" ] && [ ! -s "$NH/posts" ] && ok || bad "N3 a marked review was noted again: $(cat "$NH/log")"
# N2: the post fails -> the line, the failure line, no mark; the next call posts.
NRESET; NOTE "$T/rows31.json" 75
[ "$(grep -c . "$NH/log")" = 2 ] && [ "$(head -1 "$NH/log")" = "$NLINE" ] \
  && grep -qF 'tproj/o/tproj#81: the review-skip note did not post (rc 75) — retried next pass' "$NH/log" && ok || bad "N2 the failure lines: $(cat "$NH/log")"
[ -e "$NH/st/review-skip/o_tproj-81-31" ] && bad "N2 a failed post was marked" || ok
NOTE "$T/rows31.json" 0
[ "$(grep -c . "$NH/posts")" = 2 ] && [ -e "$NH/st/review-skip/o_tproj-81-31" ] && ok || bad "N2 the retry did not post and mark: $(cat "$NH/posts")"
# N4: a missing or garbage rows file -> silent.
NRESET; NOTE "$T/nope.json" 0; RC=$?
printf 'garbage' > "$T/garbage.json"; NOTE "$T/garbage.json" 0
[ "$RC" = 0 ] && [ ! -s "$NH/log" ] && [ ! -s "$NH/posts" ] && ok || bad "N4 a bad rows file must be silent: $(cat "$NH/log")"

# N6: observe mode -> the line says so; nothing is posted or marked.
NRESET; OBSERVE=1 NOTE "$T/rows31.json" 0
[ "$(cat "$NH/log")" = "$NLINE (observe mode: not posted)" ] && [ ! -s "$NH/posts" ] && [ ! -e "$NH/st/review-skip" ] \
  && ok || bad "N6 observe mode must log and post nothing: $(cat "$NH/log") posts=$(cat "$NH/posts")"
# N7: the post works but the mark cannot save -> it says so.
NRESET; : > "$NH/stfile"; NST="$NH/stfile" NOTE "$T/rows31.json" 0
[ "$(grep -c . "$NH/posts")" = 1 ] && grep -qF 'tproj/o/tproj#81: the review-skip note posted but its mark did not save — it can post again' "$NH/log" \
  && ok || bad "N7 a mark that did not save must be said: $(cat "$NH/log")"

# ============================================================================
# E — the real bin/blocked-resolver.sh, whole, against a real git remote
# ============================================================================
. "$(dirname "$0")/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
NOW=$(date -u +%s)
ISO() { date -u -d "@$((NOW - ${1:-0}))" '+%Y-%m-%dT%H:%M:%SZ'; }
E="$T/e"; EH="$E/h"
mkdir -p "$EH/bin/lib" "$EH/bin/blocked-resolver.d" "$EH/logs" "$EH/state" "$EH/flags" "$EH/locks" "$EH/env" "$EH/builds" \
         "$EH/state/merge-conductor" "$EH/state/build-queue/tproj" "$E/fakebin" "$E/repos" "$E/tmp"
cp "$BR" "$DIR/bin/fleet-conf.sh" "$DIR/bin/project-of.sh" "$DIR/bin/box-for.sh" "$DIR/bin/alert-line.sh" "$EH/bin/"
[ -f "$FRAG" ] && cp "$FRAG" "$EH/bin/blocked-resolver.d/"
. "$DIR/tests/lib/br-modules.sh" || exit 1
br_modules_install "$DIR" "$EH" || exit 1
export GIT_CONFIG_GLOBAL="$E/gitconfig"
printf '[user]\n\tname = t\n\temail = t@t\n' > "$GIT_CONFIG_GLOBAL"
printf 'tproj o/tproj - - 2 box-tproj 192.0.2.9\n' > "$EH/fleet.conf"
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
mrs_fixture "$EH" tproj
: > "$EH/env/global.env"
for f in run-build.sh deploy-request.sh checks-run.sh pool-cap.sh; do printf '#!/bin/bash\nexit 0\n' > "$EH/bin/$f"; done
printf '#!/bin/bash\nexit 0\n' > "$EH/bin/beat.sh"
printf '#!/bin/bash\nexit 0\n' > "$EH/bin/lane-alert.sh"
# The jobs client: an empty builds-of-record feed (bin/lib/builds-of-record.sh
# reads it from the closure), so no park is dated and nothing reads as merged.
cat > "$EH/bin/jobs-client.sh" <<EOF
queue_put() { printf '%s\n' "\$*" >> "$E/queue.txt"; echo queued; }
queue_done() { return 0; }
queue_list() { return 1; }
job_artifact_feed() { return 0; }
EOF
# The driver's real lib closure. The stubs above are written first, and the
# closure install keeps them (no-clobber).
scratch_install_closure bin/blocked-resolver.sh "$EH" >/dev/null || { echo "FAIL: closure install"; exit 1; }
chmod +x "$EH/bin/"*.sh
touch "$EH/flags/fly-pool-tproj"

ORIGIN="$E/origin.git"; SEED="$E/seed"
git init -q --bare "$ORIGIN"; git -C "$ORIGIN" symbolic-ref HEAD refs/heads/main
git init -q "$SEED"; git -C "$SEED" remote add origin "$ORIGIN"
printf '#!/bin/bash\n# a\n' > "$SEED/a.sh"
git -C "$SEED" add -A; git -C "$SEED" commit -qm base
git -C "$SEED" branch -M main; git -C "$SEED" push -q origin main
mkbranch() {
  git -C "$SEED" checkout -q main; git -C "$SEED" checkout -q -b "$1"
  printf '%s\n' "$1" > "$SEED/f-${1##*/}.txt"
  git -C "$SEED" add -A; git -C "$SEED" commit -qm "work on $1"; git -C "$SEED" push -q origin "$1"
}
mkbranch ticket/TK-81
mkbranch ticket/TK-82
git clone -q "$ORIGIN" "$E/repos/tproj"
osha() { git -C "$ORIGIN" rev-parse "$1"; }

PRWRITE() { jq -s . "$E/prrows" > "$E/openprs"; cp "$E/openprs" "$E/prlist.json"; }
PRRESET() { : > "$E/prrows"; PRWRITE; rm -f "$E/reviews-"*.json "$E/revrows-"* "$E/pr-"*.json 2>/dev/null; }
PRADD() { # PRADD <num> <head> <branch>
  jq -nc --argjson n "$1" --arg h "$2" --arg b "$3" --arg u "$(ISO 600)" --arg url "https://github.com/o/tproj/pull/$1" \
    '{number:$n, html_url:$url, title:("TK-"+($n|tostring)+": the work"), body:"body",
      head:{sha:$h, ref:$b}, base:{ref:"main"}, draft:false,
      user:{login:"operator", type:"User"}, created_at:$u, updated_at:$u,
      merged_at:null, closed_at:null, labels:[], state:"open"}' > "$E/pr-$1.json"
  cat "$E/pr-$1.json" >> "$E/prrows"; PRWRITE
}
REVADD() { # REVADD <num> <id> <state> <commit> <login> <type> <body>
  jq -nc --argjson i "$2" --arg s "$3" --arg c "$4" --arg l "$5" --arg t "$6" --arg b "$7" \
    '{id:$i, state:$s, commit_id:$c, user:{login:$l, type:$t}, author_association:"NONE", body:$b}' >> "$E/revrows-$1"
  jq -s . "$E/revrows-$1" > "$E/reviews-$1.json"
}
RL='{"resources":{"core":{"remaining":4000,"limit":5000,"reset":0},"graphql":{"remaining":4000,"limit":5000,"reset":0}}}'
export GH_BUDGET_TTL_S=0
cat > "$E/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$E/gh.txt"
N=\$(printf '%s' "\$*" | sed -nE 's#.*/(pulls|issues)/([0-9]+).*#\2#p' | head -1)
case "\$*" in
  *"-i -X GET"*"/compare/"*)
    c=\$(printf '%s' "\$*" | sed -nE 's#.*/compare/([^ ?]+).*#\1#p'); a=\${c%%...*}; b=\${c#*...}
    git -C "$ORIGIN" cat-file -e "\$a^{commit}" 2>/dev/null || { printf 'HTTP/2 404\r\n\r\n{"message":"Not Found"}'; exit 0; }
    out=\$(git -C "$ORIGIN" rev-list --reverse --parents "\$a..\$b" | jq -Rsc 'split("\n") | map(select(. != "") | split(" ")) | map({sha:.[0], parents:(.[1:] | map({sha:.}))}) | {status:(if length > 0 then "ahead" else "identical" end), commits:.}')
    printf 'HTTP/2 200\r\n\r\n%s' "\$out"; exit 0 ;;
  *"-i -X "*)
    GHT="$E"
    jq -r '.head.sha // ""' "$E/pr-\$N.json" 2>/dev/null > "$E/prhead"
    jq -r '.head.ref // ""' "$E/pr-\$N.json" 2>/dev/null > "$E/prbranch"
    jq -r '.title // ""'    "$E/pr-\$N.json" 2>/dev/null > "$E/prtitle"
    . "$DIR/tests/lib/gh-rest-stub.sh"; gh_rest_stub "\$@" ;;
  *"api rate_limit"*) printf '%s\n' '$RL' ;;
  *"pr comment"*) printf 'pr comment %s\n' "\$2" >> "$E/comments.txt"; exit 0 ;;
  *"--json state"*) echo OPEN ;;
  *"/pulls/"*)
    JQX=""; PREV=""
    for A in "\$@"; do case "\$PREV" in --jq|-q) JQX="\$A" ;; esac; PREV="\$A"; done
    if [ -n "\$JQX" ]; then jq -r "\$JQX" "$E/pr-\$N.json" 2>/dev/null; else cat "$E/pr-\$N.json" 2>/dev/null; fi ;;
  *"--json headRefName"*) echo "ticket/ts-\$N" ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$E/fakebin/gh"
printf '#!/bin/bash\nexit 0\n' > "$E/fakebin/flock"; chmod +x "$E/fakebin/flock"
printf '#!/bin/bash\nexit 0\n' > "$E/fakebin/br-ssh"; chmod +x "$E/fakebin/br-ssh"
echo OPEN > "$E/prstate"
cat > "$EH/bin/agent-call.sh" <<EOF
#!/bin/bash
printf 'agent-call %s\n' "\$1" >> "$E/agent.txt"
printf 'fixed\n' >> a.sh
git add -A >/dev/null 2>&1
git -c user.email=t@t -c user.name=t commit -q -m "fix round" >/dev/null 2>&1
exit 0
EOF
chmod +x "$EH/bin/agent-call.sh"
OLDPATH="$PATH"; export PATH="$E/fakebin:$OLDPATH" GH_TOKEN="" TMPDIR="$E/tmp"
RUN() { ( HARNESS="$EH" FLEET_CONF="$EH/fleet.conf" REPOS_ROOT="$E/repos" BR_SSH="$E/fakebin/br-ssh" \
          bash "$EH/bin/blocked-resolver.sh" >>"$E/run.log" 2>&1 ) || true; }
# ERESET — a fresh case: no state, no logs, no posts, no agent calls.
ERESET() {
  : > "$E/agent.txt"; : > "$EH/logs/blocked-resolver.log"; rm -f "$E/comments.txt" "$E/comment-bodies.txt" "$E/st-comment"
  scratch_rm "$EH/state/gh-budget"; scratch_rm "$EH/state/blocked-resolver"
}
NAGENT() { grep -c . "$E/agent.txt" 2>/dev/null || true; }
CAND() { # the reviews source's candidate rows, from the driver's own functions
  awk '/^DONE_KEYS=/{exit} {print}' "$EH/bin/blocked-resolver.sh" > "$E/br-lib.sh"
  ( HARNESS="$EH" FLEET_CONF="$EH/fleet.conf" REPOS_ROOT="$E/repos" BRLIB="$E/br-lib.sh" \
    bash -c 'L="$BRLIB"; set --; . "$L" 2>/dev/null; ONLY=""; br_from_reviews' 2>/dev/null ) | grep -F $'\treview-changes-requested\t' || true
}
# Each count reads through cat, so a file that was never written counts 0, never "".
NNOTE()  { cat "$EH/logs/blocked-resolver.log" 2>/dev/null | grep -c 'is not a harness verdict' || true; }
NPOST()  { cat "$E/comments.txt" 2>/dev/null | grep -c "POST.*repos/o/tproj/issues/$1/comments" || true; }
NBODY()  { cat "$E/comment-bodies.txt" 2>/dev/null | grep -c 'is not a harness verdict' || true; }

# ── E1: a user's VERDICT: REQUEST_CHANGES review on the head -> one note, one post, no round ──
S81=$(osha ticket/TK-81)
PRRESET; PRADD 81 "$S81" ticket/TK-81
REVADD 81 5643798807 COMMENTED "$S81" mac-drain User "$UBODY"
ERESET; RUN
ELINE="tproj/o/tproj#81: review 5643798807 by mac-drain on ${S81:0:12} is not a harness verdict (author,footer) $NOTE_TAIL"
[ "$(NNOTE)" = 1 ] && grep -qF "$ELINE" "$EH/logs/blocked-resolver.log" && ok || bad "E1 want exactly one note line '$ELINE', got $(NNOTE): $(grep 'harness verdict' "$EH/logs/blocked-resolver.log")"
[ "$(NPOST 81)" = 1 ] && [ "$(NBODY)" = 1 ] && grep -qF "$ELINE" "$E/comment-bodies.txt" && ok || bad "E1 want exactly one PR comment with the line, got $(NPOST 81): $(cat "$E/comment-bodies.txt" 2>/dev/null)"
[ "$(NAGENT)" = 0 ] && ok || bad "E1 a user review started a fix round ($(NAGENT))"
[ -z "$(CAND)" ] && ok || bad "E1 a user review became a fix-round candidate: $(CAND)"
[ "$(osha ticket/TK-81)" = "$S81" ] && ok || bad "E1 the branch moved"
# ── E2: the second pass on the same state -> nothing new ──
: > "$EH/logs/blocked-resolver.log"; scratch_rm "$EH/state/gh-budget"; RUN
[ "$(NNOTE)" = 0 ] && ok || bad "E2 the second pass noted again ($(NNOTE))"
[ "$(NPOST 81)" = 1 ] && ok || bad "E2 want 1 post over two passes, got $(NPOST 81)"
[ "$(NAGENT)" = 0 ] && ok || bad "E2 a user review started a fix round ($(NAGENT))"
# ── E4: a second user review id on the same head -> its own note ──
REVADD 81 5643799900 COMMENTED "$S81" mac-drain User "$UBODY"
: > "$EH/logs/blocked-resolver.log"; scratch_rm "$EH/state/gh-budget"; RUN
[ "$(NNOTE)" = 1 ] && grep -qF "review 5643799900 by mac-drain" "$EH/logs/blocked-resolver.log" && ok || bad "E4 a new review id must get its own note ($(NNOTE))"
[ "$(NPOST 81)" = 2 ] && ok || bad "E4 want a second post, got $(NPOST 81)"
[ "$(NAGENT)" = 0 ] && ok || bad "E4 a user review started a fix round ($(NAGENT))"

# ── E5: the post fails (500) -> no mark; the next pass posts ──
PRRESET; PRADD 81 "$S81" ticket/TK-81
REVADD 81 5643798807 COMMENTED "$S81" mac-drain User "$UBODY"
ERESET; echo 500 > "$E/st-comment"; RUN
grep -qF 'tproj/o/tproj#81: the review-skip note did not post' "$EH/logs/blocked-resolver.log" && ok || bad "E5 the failed post was not said: $(grep 'review-skip\|harness verdict' "$EH/logs/blocked-resolver.log")"
rm -f "$E/st-comment"; : > "$E/comments.txt"; : > "$EH/logs/blocked-resolver.log"; scratch_rm "$EH/state/gh-budget"; RUN
[ "$(NNOTE)" = 1 ] && [ "$(NPOST 81)" = 1 ] && ok || bad "E5 the pass after a failed post must post (notes $(NNOTE), posts $(NPOST 81))"

# ── E3: a harness-footer review from a verdict author -> its fix round, nothing noted ──
S82=$(osha ticket/TK-82)
PRRESET; PRADD 82 "$S82" ticket/TK-82
# BH-8419: the harness verdict is posted by the App, never the operator login.
REVADD 82 7001 COMMENTED "$S82" 'cromford[bot]' Bot "$(HFOOT REQUEST_CHANGES "$S82")"
ERESET; RUN
[ "$(NAGENT)" = 1 ] && ok || bad "E3 a harness verdict must start exactly one fix round, got $(NAGENT) (log: $(tail -5 "$EH/logs/blocked-resolver.log"))"
[ "$(grep -c . <<<"$(CAND)")" = 1 ] && ok || bad "E3 control: the harness verdict must be one candidate: $(CAND)"
[ "$(NNOTE)" = 0 ] && [ "$(NBODY)" = 0 ] && ok || bad "E3 a harness verdict was noted: $(grep 'harness verdict' "$EH/logs/blocked-resolver.log")"

# ── N5: BR_OPT_OFF names the fragment -> the user review is not noted, no round ──
PRRESET; PRADD 81 "$S81" ticket/TK-81
REVADD 81 5643798807 COMMENTED "$S81" mac-drain User "$UBODY"
ERESET; BR_OPT_OFF=bh-8307-review-skip-note RUN
[ "$(NNOTE)" = 0 ] && [ "$(NPOST 81)" = 0 ] && [ "$(NAGENT)" = 0 ] && ok || bad "N5 BR_OPT_OFF must turn the note off (notes $(NNOTE), posts $(NPOST 81), rounds $(NAGENT))"
export PATH="$OLDPATH"

echo "resolver-review-skip-note.bh-8307: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
