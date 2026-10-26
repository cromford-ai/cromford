#!/bin/bash
# tests/comment-mark.bh-2317-test.sh — BH-2317: the four "this comment is
# already on the thread" markers are ledgers(kind=commented) rows first and
# state files second, and a re-offer clears the ROW instead of ssh-ing to a box.
#
# What the ticket asked for, and where each case pins it:
#   A1–A4, N1–N3  bin/lib/comment-mark.sh's read rule, on its own
#   A5            bin/lib/rb/execute.sh's BUILD BLOCKED notice: a wiped state/
#                 with the row present posts NOTHING
#   A6            bin/lib/rb/pr.sh's tier-1 merge-close comment, the same, and
#                 the row is flipped to `cleared` once the close lands
#   A7            bin/decompose-parent-close.sh, driven as the real script
#   A8            bin/blocked-resolver.sh's br_ticket_comment: the marker file
#                 deleted, the row still stops a second post
#   A9/A10        bin/pr-owner-sweep.sh's handback: worker up = row cleared, no
#                 ssh; worker down = no ssh, rc 1 and the named line (BH-2673)
# The resolver's own re-offer (the other ssh rm) is driven through a real tick
# in tests/blocked-resolver-record-rows.bh-2317-test.sh.
#
# The jobs DB is modelled on disk ($T/db): job_ledger_row/get/put answer rc 0
# row, rc 2 no row, rc 1 when $T/db-down exists — the three answers the real
# client gives. Every assertion is on an artifact: the gh call log, the ssh
# log, the rows, the files.
#
# Run from anywhere: tests/comment-mark.bh-2317-test.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
export GH_CLI_REST_ADAPTER="$DIR/tests/lib/gh-cli-rest-adapter.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "FAIL: python3 is required by bin/decompose-parent-close.sh"; exit 1; }

SLUG="example-org/cromford"
CM="$DIR/bin/lib/comment-mark.sh"

# ── the jobs DB, on disk ─────────────────────────────────────────────────────
# The PUT keeps the old detail when none is sent — the route's COALESCE.
DB="$T/db"; export DB
cat > "$T/jobs-stub.sh" <<'JS'
_db() { printf '%s/%s--%s' "$DB" "$1" "$(printf '%s' "$2" | tr -c 'A-Za-z0-9._-' _)"; }
job_ledger_row() { [ -e "$DB-down" ] && return 1; [ -f "$(_db "$1" "$2")" ] || return 2; cat "$(_db "$1" "$2")"; }
job_ledger_get() { local r; r=$(job_ledger_row "$@") || return $?; printf '%s' "$r" | jq -r .status; }
job_ledger_put() {
  [ -e "$DB-down" ] && return 1
  local f d="${4:-}"; f=$(_db "$1" "$2"); mkdir -p "$DB"
  [ -z "$d" ] && [ -f "$f" ] && d=$(jq -r .detail "$f")
  jq -nc --arg s "$3" --arg d "$d" '{status:$s,detail:$d}' > "$f"
}
JS
row()    { cat "$DB/$1--$(printf '%s' "$2" | tr -c 'A-Za-z0-9._-' _)" 2>/dev/null; }
rowst()  { row "$@" | jq -r .status 2>/dev/null; }
dbdown() { : > "$DB-down"; }
dbup()   { rm -f "$DB-down"; }
wipedb() { scratch_rm "$DB"; dbup; }

# ════════════════════════════════════════════════════════════════════════════
# A1–A4, N1–N3 — the read rule
# ════════════════════════════════════════════════════════════════════════════
unit() { # unit <shell text> — rc of the text with the lib and the DB loaded
  DB="$DB" bash -c '. "$1"; . "$2"; eval "$3"' _ "$T/jobs-stub.sh" "$CM" "$1" >/dev/null 2>&1
}
U="$T/unit"; mkdir -p "$U"
wipedb
unit 'cm_put "blocked p TK-9" b1 "'"$U"'/s1"'; RC=$?
[ "$RC" = 0 ] && ok || bad "A1: cm_put must answer 0 (rc=$RC)"
[ "$(row commented 'blocked p TK-9')" = '{"status":"commented","detail":"b1"}' ] && ok \
  || bad "A1: the row must say commented with the token as detail: $(row commented 'blocked p TK-9')"
[ -e "$U/s1" ] && ok || bad "A1: cm_put must still write the file"
unit 'cm_has "blocked p TK-9" b1 "'"$U"'/s1"' && ok || bad "A1: a put comment must read as marked"
rm -f "$U/s1"
unit 'cm_has "blocked p TK-9" b1 "'"$U"'/s1"' && ok || bad "A1: the ROW alone must answer marked when the file is gone"

wipedb
unit 'cm_has "blocked p TK-9" b1 "'"$U"'/none"' && bad "A2: no row and no file must read as NOT marked" || ok

wipedb; : > "$U/s3"
unit 'cm_clear "blocked p TK-9" "'"$U"'/nothing-*"'; RC=$?
[ "$RC" = 0 ] && ok || bad "A3: a cleared row must answer rc 0 (rc=$RC)"
[ "$(rowst commented 'blocked p TK-9')" = cleared ] && ok || bad "A3: cm_clear must flip the row to cleared"
unit 'cm_has "blocked p TK-9" b1 "'"$U"'/s3"' && bad "A3: a cleared row must beat a stale file" || ok

wipedb; : > "$U/s4"; dbdown
unit 'cm_has "blocked p TK-9" b1 "'"$U"'/s4"' && ok || bad "A4: an outage with the file present must read as marked"
unit 'cm_has "blocked p TK-9" b1 "'"$U"'/none"' && bad "A4: an outage with no file must read as NOT marked" || ok
unit 'cm_clear "blocked p TK-9" "'"$U"'/s4"'; RC=$?
[ "$RC" = 1 ] && ok || bad "A4: a clear the DB did not take must answer rc 1 (rc=$RC)"
[ ! -e "$U/s4" ] && ok || bad "A4: cm_clear must still remove the local file on an outage"
dbup

# N1 — the key is exact: TK-91's row never marks TK-9.
wipedb
unit 'cm_put "blocked p TK-91" b1 "'"$U"'/n1"'
unit 'cm_has "blocked p TK-9" b1 "'"$U"'/none"' && bad "N1: TK-91's row must not mark TK-9" || ok
# N2 — a status the rule does not know falls through to the file, both ways.
wipedb; mkdir -p "$DB"; : > "$U/n2"
printf '{"status":"weird","detail":"b1"}' > "$DB/commented--blocked_p_TS-9"
unit 'cm_has "blocked p TK-9" b1 "'"$U"'/n2"' && ok || bad "N2: an unknown status must fall to the file (present -> marked)"
unit 'cm_has "blocked p TK-9" b1 "'"$U"'/none"' && bad "N2: an unknown status must fall to the file (absent -> not marked)" || ok
# N3 — a row for ANOTHER build of the key never unmarks this build's own file.
wipedb; : > "$U/n3"
unit 'cm_put "blocked p TK-9" b2 "'"$U"'/other"'
unit 'cm_has "blocked p TK-9" b1 "'"$U"'/n3"' && ok || bad "N3: another token's row must leave this build's file in charge"
unit 'cm_has "blocked p TK-9" b1 "'"$U"'/none"' && bad "N3: another token's row must not mark this build" || ok


# ── the stub gh ──────────────────────────────────────────────────────────────
# REST calls answer from $CASE/<kind>.resp (`<code>` on line 1, body after);
# the CLI reads this slice does not convert answer from their own fixtures.
# Every invocation is logged in order, which is what the ordering assertions
# read.
mkdir -p "$T/bin"
cat > "$T/bin/gh" <<'STUB'
#!/bin/bash
[ -f "$CASE/issues.resp" ] || { . "${GH_CLI_REST_ADAPTER:?}" || exit 1; gh_cli_rest "$0" "$@" && exit 0; }
printf '%s\n' "$*" >> "$CASE/gh-calls.log"
if [ "${1:-}" != api ]; then
  case "$*" in
    *"issue list"*) cat "$CASE/issues-list.json" 2>/dev/null || echo '[]' ;;
    *"pr list"*)    cat "$CASE/prs-list.json"    2>/dev/null || echo '[]' ;;
    *"issue view"*)
      n=$(printf '%s' "$*" | sed -nE 's/.*issue view ([0-9]+).*/\1/p')
      cat "$CASE/issue-$n.json" 2>/dev/null || exit 1 ;;
    *"pr view"*)    cat "$CASE/pr-head.txt"      2>/dev/null || exit 1 ;;
    *) exit 1 ;;
  esac
  exit 0
fi
M=GET; P=""; prev=""
for a in "$@"; do
  [ "$prev" = -X ] && M="$a"
  case "$a" in repos/*) P="$a" ;; esac
  prev="$a"
done
case "$M $P" in
  "POST "*/comments) K=comment ;;
  "PATCH "*)         K=close ;;
  "GET "*/labels)    K=labels ;;
  "GET "*/issues)    K=issues ;;
  "GET "*/files)     cat "$CASE/pr-files.json" 2>/dev/null || echo '[]'; exit 0 ;;
  # A PULL READ IS THE ONE THE STUB HAS TO MODEL, not answer from a constant.
  # settle_member now reads the PR's state BEFORE it writes, and gh_rest_close
  # re-reads the same path AFTER its PATCH — two GETs on one path that must give
  # different answers. A case that writes prread.resp gets the modelled object:
  # this read answers from it, and the PATCH below advances it to `closed` only
  # when the PATCH itself was accepted. Cases that do not write it are answered
  # from read.resp exactly as before.
  "GET "*/pulls/*)   K=read; [ -f "$CASE/prread.resp" ] && K=prread ;;
  "GET "*)           K=read ;;
  *)                 K=other ;;
esac
F="$CASE/$K.resp"
[ -f "$F" ] || exit 1
CODE=$(head -n 1 "$F"); BODY=$(tail -n +2 "$F")
[ "$CODE" = none ] && exit 1
case "$CODE" in
  200) TXT="OK" ;; 201) TXT="Created" ;; 403) TXT="Forbidden" ;;
  404) TXT="Not Found" ;; 429) TXT="Too Many Requests" ;; *) TXT="Status" ;;
esac
case " $* " in
  *" -i "*) printf 'HTTP/2.0 %s %s\nx-stub: 1\n\n%s' "$CODE" "$TXT" "${BODY:+$BODY
}" ;;
  *) [ -n "$BODY" ] && printf '%s\n' "$BODY" ;;
esac
# THE OBJECT MOVES ONLY WHEN THE WRITE WAS ACCEPTED. A refused PATCH leaves the
# PR open, which is what makes a second pass a real retry rather than a replay.
# AND A MERGED PR NEVER BECOMES PLAIN `closed`: GitHub accepts `state=closed` on
# a merged PR with a 200 and keeps merged_at, so gh_rest_pr_state keeps
# answering `merged` and gh_rest_close keeps answering 75. Flattening it here
# would hide exactly the "this member never settles" bug the BR5 case is for.
case "$M $P:$CODE" in
  "PATCH "*/pulls/*:2*)
    if [ -f "$CASE/prread.resp" ] && ! grep -q merged_at "$CASE/prread.resp"; then
      printf '200\n{"state":"closed"}\n' > "$CASE/prread.resp"
    fi ;;
esac
case "$CODE" in 2*) exit 0 ;; *) exit 1 ;; esac
STUB
chmod +x "$T/bin/gh"

resp() { printf '%s\n%s\n' "$2" "$3" > "$CASE/$1.resp"; }
calls()  { cat "$CASE/gh-calls.log" 2>/dev/null; }
ncalls() { calls | grep -c . ; }
nth()    { calls | sed -n "${1}p"; }

newcase() { # newcase <name> — a fresh scratch harness with the stub on PATH
  CASE="$T/case-$1"; export CASE
  H="$CASE/h"
  mkdir -p "$H/bin/lib" "$H/logs" "$H/state" "$H/flags" "$H/env" "$H/builds"
  cp "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$DIR/bin/lib/gh-rest-list.sh" "$H/bin/lib/"
  printf '#!/bin/bash\nexit 0\n' > "$H/bin/beat.sh"; chmod +x "$H/bin/beat.sh"
  cp "$CM" "$H/bin/lib/"
  # BH-7919: escalate_block's ticket comment now asks bin/lib/tracker.sh trk_gh_issue_number.
  scratch_install_closure bin/lib/tracker.sh "$H" >/dev/null || exit 1
  : > "$CASE/gh-calls.log"
  resp comment 201 '{"id":1}'
  resp close   200 '{"state":"closed"}'
  resp read    200 '{"state":"closed"}'
  export PATH="$T/bin:$H/bin:$PATH"
  wipedb
}
posts() { calls | grep -c -- '-X POST' ; }

# The pipeline as one text (tests/lib/rb-all.sh), and the functions under test
# lifted out of it together with the gh-rest source line the driver carries.
# shellcheck source=/dev/null
. "$DIR/tests/lib/rb-all.sh" || exit 1
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh")
[ -s "$RB_ALL" ] && ok || bad "R: the flattened bin/run-build.sh is empty"
RB_SRC=$(grep -m1 -E '^[^#]*lib/gh-rest\.sh' "$RB_ALL")
awk '/^CLOSE_ISSUE_AFTER_MERGE\(\) \{/,/^\}/' "$RB_ALL" > "$T/close-fn.sh"
awk '/^escalate_block\(\) \{/,/^\}/'          "$RB_ALL" > "$T/escalate-fn.sh"
[ -s "$T/close-fn.sh" ] && [ -s "$T/escalate-fn.sh" ] && ok || bad "R: could not extract the close-out functions"
cat > "$T/drive.sh" <<'DRIVE'
#!/bin/bash
set -uo pipefail
STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
eval "$RB_SRC"
. "$JSTUB"
. "$FN"
"$@"
DRIVE
drv() { # drv <fn-file> <call...>
  local fn="$1"; shift
  HARNESS="$H" SLUG="$SLUG" PROJECT=cromford KEY=BH-781 BUILD="$H/builds/b" \
    CLOSES_LINE="Closes #7" RB_SRC="$RB_SRC" JSTUB="$T/jobs-stub.sh" FN="$fn" DB="$DB" \
    bash "$T/drive.sh" "$@" >/dev/null 2>&1
}
fleetconf() {
  cat > "$H/bin/fleet-conf.sh" <<'SH'
#!/bin/bash
case "$2" in board_prefix) echo "-" ;; repo) echo "example-org/cromford" ;; *) exit 1 ;; esac
SH
  chmod +x "$H/bin/fleet-conf.sh"
}

# ════════════════════════════════════════════════════════════════════════════
# A5 — the BUILD BLOCKED notice survives a wiped state/
# ════════════════════════════════════════════════════════════════════════════
newcase a5; fleetconf; mkdir -p "$H/builds/b"
drv "$T/escalate-fn.sh" escalate_block test-tamper "the detail line"
[ "$(posts)" = 1 ] && ok || bad "A5: the first blocked notice must be posted once: $(calls)"
[ "$(row commented 'blocked cromford BH-781')" = '{"status":"commented","detail":"b"}' ] && ok \
  || bad "A5: the notice must leave a commented row keyed by project+key, token = build: $(row commented 'blocked cromford BH-781')"
scratch_rm "$H/state"; mkdir -p "$H/state"
drv "$T/escalate-fn.sh" escalate_block test-tamper "the detail line"
[ "$(posts)" = 1 ] && ok || bad "A5: a wiped state/ with the row present must post NOTHING: $(calls)"
# The control: the same wipe with the DB down is today's behaviour — it posts
# again. It is what makes the assertion above about the row and not the stub.
scratch_rm "$H/state"; mkdir -p "$H/state"; dbdown
drv "$T/escalate-fn.sh" escalate_block test-tamper "the detail line"
[ "$(posts)" = 2 ] && ok || bad "A5: control — with the DB down and no file the notice is posted again: $(calls)"
dbup
# A refused POST writes neither the row nor the file (BH-781's ordering).
newcase a5b; fleetconf; mkdir -p "$H/builds/b"
resp comment 403 '{"message":"API rate limit exceeded"}'
drv "$T/escalate-fn.sh" escalate_block test-tamper "the detail line"
[ -z "$(row commented 'blocked cromford BH-781')" ] && ok || bad "A5: a refused notice must write no row"
[ -z "$(ls "$H"/state/blocked-commented-* 2>/dev/null)" ] && ok || bad "A5: a refused notice must write no stamp"

# ════════════════════════════════════════════════════════════════════════════
# A6 — the tier-1 merge-close comment
# ════════════════════════════════════════════════════════════════════════════
newcase a6; mkdir -p "$H/builds/b"; : > "$H/builds/b/pipeline.log"
resp close 403 '{"message":"API rate limit exceeded"}'
drv "$T/close-fn.sh" CLOSE_ISSUE_AFTER_MERGE "https://github.com/$SLUG/pull/9"
[ "$(posts)" = 1 ] && ok || bad "A6: the close comment must be posted once: $(calls)"
[ "$(rowst commented "merge-close $SLUG 7")" = commented ] && ok || bad "A6: the comment must leave a commented row"
scratch_rm "$H/state"; mkdir -p "$H/state"
drv "$T/close-fn.sh" CLOSE_ISSUE_AFTER_MERGE "https://github.com/$SLUG/pull/9"
[ "$(posts)" = 1 ] && ok || bad "A6: a wiped state/ with the row present must not re-post: $(calls)"
[ "$(calls | grep -c -- '-X PATCH')" = 2 ] && ok || bad "A6: the CLOSE is still retried: $(calls)"
resp close 200 '{"state":"closed"}'
drv "$T/close-fn.sh" CLOSE_ISSUE_AFTER_MERGE "https://github.com/$SLUG/pull/9"
[ "$(posts)" = 1 ] && ok || bad "A6: the pass that closes must not re-post: $(calls)"
[ "$(rowst commented "merge-close $SLUG 7")" = cleared ] && ok || bad "A6: a landed close must flip the row to cleared"
[ ! -e "$H/state/merge-close-commented-${SLUG//\//_}-7" ] && ok || bad "A6: a landed close must drop the file"

# ════════════════════════════════════════════════════════════════════════════
# A7 — the split parent's close comment, through the real script
# ════════════════════════════════════════════════════════════════════════════
dp_setup() {
  cp "$DIR/bin/decompose-parent-close.sh" "$H/bin/"
  cp "$DIR/bin/lib/revdep-lib.sh" "$DIR/bin/lib/env-path.sh" "$H/bin/lib/" 2>/dev/null
  cp "$T/jobs-stub.sh" "$H/bin/jobs-client.sh"
  cat > "$CASE/issues-list.json" <<'JSON'
[{"number":11,"state":"CLOSED","stateReason":"COMPLETED","title":"BH-9.1 first part","body":"Part of #9\nOrder: 1 of 1"}]
JSON
  cat > "$CASE/prs-list.json" <<'JSON'
[{"number":12,"url":"https://github.com/example-org/cromford/pull/12","title":"BH-11: first part","headRefName":"ticket/bh-11","state":"MERGED"}]
JSON
  printf '{"number":9,"state":"OPEN","title":"the parent","labels":[]}\n' > "$CASE/issue-9.json"
}
dp() { HARNESS="$H" DB="$DB" GH_ISSUES_REPO="$SLUG" GH_CLI_REST_READS=1 "$H/bin/decompose-parent-close.sh" cromford 2>/dev/null; }
pposts() { calls | grep -c -- '-X POST.*issues/9/comments' ; }
newcase a7; dp_setup
resp close 403 '{"message":"API rate limit exceeded"}'
dp >/dev/null
[ "$(pposts)" = 1 ] && ok || bad "A7: the parent close comment must be posted once: $(calls)"
[ "$(rowst commented 'parent-close cromford 9')" = commented ] && ok || bad "A7: the comment must leave a commented row"
scratch_rm "$H/state"; mkdir -p "$H/state"
dp >/dev/null
[ "$(pposts)" = 1 ] && ok || bad "A7: a wiped state/ with the row present must not re-post: $(calls)"
resp close 200 '{"state":"closed"}'
OUT=$(dp)
[ "$OUT" = 9 ] && ok || bad "A7: the close that lands must print the parent (got '$OUT')"
[ "$(pposts)" = 1 ] && ok || bad "A7: the pass that closes must not re-post: $(calls)"
[ "$(rowst commented 'parent-close cromford 9')" = cleared ] && ok || bad "A7: a landed close must flip the row to cleared"
[ ! -e "$H/state/parent-close-commented-cromford-9" ] && ok || bad "A7: a landed close must drop the file"

# ════════════════════════════════════════════════════════════════════════════
# A8 — the resolver's rebuild-outcome comment
# ════════════════════════════════════════════════════════════════════════════
# fn_body: the function exactly as bin/blocked-resolver.sh carries it.
fn_body() {
  awk -v P="$2() {" '
    !f && substr($0, 1, length(P)) == P && /\}[[:space:]]*$/ { print; exit }
    substr($0, 1, length(P)) == P    { f=1 }
    f                                { print }
    f && /^\}$/                      { exit }' "$1"
}
fn_body "$DIR/bin/blocked-resolver.sh" br_ticket_comment > "$T/btc.sh"
[ -s "$T/btc.sh" ] && ok || bad "A8: could not lift br_ticket_comment out of bin/blocked-resolver.sh"
# The resolver loads the lib at the top of the lane; the lifted function is
# driven beside the same source line.
CMSRC=$(grep -m1 -E '^[^#]*lib/comment-mark\.sh' "$DIR/bin/blocked-resolver.sh")
[ -n "$CMSRC" ] && ok || bad "A8: bin/blocked-resolver.sh must source bin/lib/comment-mark.sh"
cat > "$T/drive-btc.sh" <<'DRIVE'
#!/bin/bash
set -uo pipefail
H="$HARNESS"; ST="$H/state/blocked-resolver"
say() { :; }
br_issue_comment() { printf '%s#%s\n' "$1" "$2" >> "$CASE/posts.log"; return 0; }
br_comment_refused() { printf 'refused %s\n' "$5" >> "$CASE/posts.log"; }
. "$JSTUB"
eval "$CMSRC"
. "$FN"
br_ticket_comment tproj tproj-TK-9 TK-9 REVIEW_BLOCKED /art https://github.com/o/tproj/pull/9
DRIVE
btc() { HARNESS="$H" CASE="$CASE" DB="$DB" JSTUB="$T/jobs-stub.sh" CMSRC="$CMSRC" FN="$T/btc.sh" bash "$T/drive-btc.sh" >/dev/null 2>&1; }
newcase a8
printf '#!/bin/bash\ncase "$2" in board_prefix) echo "-" ;; repo) echo o/tproj ;; *) exit 1 ;; esac\n' > "$H/bin/fleet-conf.sh"
chmod +x "$H/bin/fleet-conf.sh"
MK="$H/state/blocked-resolver/tproj/tproj-TK-9.rebuild-commented"
btc
[ "$(grep -c . "$CASE/posts.log" 2>/dev/null)" = 1 ] && ok || bad "A8: the first rebuild comment must be posted: $(cat "$CASE/posts.log" 2>/dev/null)"
[ "$(rowst commented 'rebuild tproj tproj-TK-9')" = commented ] && ok || bad "A8: the comment must leave a commented row"
rm -f "$MK"
btc
[ "$(grep -c . "$CASE/posts.log")" = 1 ] && ok || bad "A8: the marker file deleted, the row must still stop a second post: $(cat "$CASE/posts.log")"
rm -f "$MK"; dbdown
btc
[ "$(grep -c . "$CASE/posts.log")" = 2 ] && ok || bad "A8: control — DB down and no file posts again, as today: $(cat "$CASE/posts.log")"
dbup

# ════════════════════════════════════════════════════════════════════════════
# A9/A10 — pr-owner-sweep's hand-back clears the ROW; an outage is rc 1, no ssh
# ════════════════════════════════════════════════════════════════════════════
fn_body "$DIR/bin/pr-owner-sweep.sh" handback > "$T/handback.sh"
[ -s "$T/handback.sh" ] && ok || bad "A9: could not lift handback out of bin/pr-owner-sweep.sh"
POSSRC=$(grep -m1 '^pos_pool_routed()' "$DIR/bin/pr-owner-sweep.sh")
CMSRC2=$(grep -m1 -E '^[^#]*lib/comment-mark\.sh' "$DIR/bin/pr-owner-sweep.sh")
[ -n "$CMSRC2" ] && ok || bad "A9: bin/pr-owner-sweep.sh must source bin/lib/comment-mark.sh"
cat > "$T/drive-hb.sh" <<'DRIVE'
#!/bin/bash
set -uo pipefail
H="$HARNESS"
say() { printf '%s\n' "$*" >> "$CASE/say.log"; }
# ssh resolves to $CASE/ssh, the recording shim. SSH_CMD is what the pre-BH-2673
# handback called, so an old fallback would land in the log, not in an unbound var.
export PATH="$CASE:$PATH"; SSH_CMD=ssh
. "$JSTUB"
eval "$CMSRC2"
eval "$POSSRC"
. "$FN"
handback project-5 TK-909
DRIVE
hb() { HARNESS="$H" CASE="$CASE" DB="$DB" DRY="${DRY:-0}" JSTUB="$T/jobs-stub.sh" CMSRC2="$CMSRC2" POSSRC="$POSSRC" \
         FN="$T/handback.sh" bash "$T/drive-hb.sh" >/dev/null 2>&1; }
hb_setup() {
  printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/ssh-calls.log"\nexit 0\n' "$CASE" > "$CASE/ssh"; chmod +x "$CASE/ssh"
  printf '#!/bin/bash\necho "${FAKE_BOX:-box-project-5-1}"\n' > "$H/bin/box-for.sh"; chmod +x "$H/bin/box-for.sh"
  printf '#!/bin/bash\n[ "$1" = --tailnet-ip ] && echo 10.0.0.5\n' > "$H/bin/fleet-conf.sh"; chmod +x "$H/bin/fleet-conf.sh"
  : > "$CASE/ssh-calls.log"
}
newcase a9; hb_setup
hb; RC=$?
[ "$RC" = 0 ] && ok || bad "A9: a hand-back whose row cleared must answer 0 (rc=$RC)"
[ "$(rowst commented 'blocked project-5 TK-909')" = cleared ] && ok || bad "A9: the hand-back must flip the blocked row to cleared"
[ ! -s "$CASE/ssh-calls.log" ] && ok || bad "A9: a hand-back the DB took must not ssh to the box: $(cat "$CASE/ssh-calls.log")"
# local ownership: the row, and the hub's own files go too
newcase a9l; hb_setup; touch "$H/state/blocked-commented-project-5-TK-909-b1"
FAKE_BOX=local hb
[ ! -e "$H/state/blocked-commented-project-5-TK-909-b1" ] && ok || bad "A9: a locally owned key's stamp must be removed in place"
[ "$(rowst commented 'blocked project-5 TK-909')" = cleared ] && ok || bad "A9: a locally owned key's row must be cleared too"
# DRY-RUN writes nothing and says what it would do
newcase a9d; hb_setup
DRY=1 hb
[ -z "$(row commented 'blocked project-5 TK-909')" ] && [ ! -s "$CASE/ssh-calls.log" ] && ok || bad "A9: DRY-RUN must write no row and ssh nowhere"
grep -q 'DRY-RUN would: clear row blocked project-5 TK-909' "$CASE/say.log" 2>/dev/null && ok \
  || bad "A9: DRY-RUN must name the row it would clear: $(cat "$CASE/say.log" 2>/dev/null)"
# A10 — the DB is down: nothing is handed back, rc 1, one named line, no ssh
# (BH-2673). fleet-conf.sh answers a tailnet_ip, so the old fallback had a target.
HBDOWN='project-5/TK-909: row not written; jobs DB unreachable; the hand-back is retried next sweep'
newcase a10; hb_setup; dbdown
hb; RC=$?
[ "$RC" = 1 ] && ok || bad "A10: an unwritten row must answer 1 (rc=$RC)"
[ ! -s "$CASE/ssh-calls.log" ] && ok || bad "A10: a DB outage must not fall back to ssh: $(cat "$CASE/ssh-calls.log")"
grep -qF "$HBDOWN" "$CASE/say.log" 2>/dev/null && ok || bad "A10: the outage must be named: $(cat "$CASE/say.log" 2>/dev/null)"
dbup
# A10l — locally owned and the DB is down: still rc 1, the hub's stamp still goes
newcase a10l; hb_setup; dbdown; touch "$H/state/blocked-commented-project-5-TK-909-b1"
FAKE_BOX=local hb; RC=$?
[ "$RC" = 1 ] && ok || bad "A10l: a local key with the row unwritten must answer 1 (rc=$RC)"
[ ! -e "$H/state/blocked-commented-project-5-TK-909-b1" ] && ok || bad "A10l: cm_clear must still remove the local stamp"
[ ! -s "$CASE/ssh-calls.log" ] && ok || bad "A10l: no ssh: $(cat "$CASE/ssh-calls.log")"
dbup

echo "comment-mark.bh-2317-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
