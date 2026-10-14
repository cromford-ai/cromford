#!/bin/bash
# tests/external-pr-handback.bh-4669-test.sh — BH-4664.2 (BH-4669): an external
# PR is handed back to its author, once per head, and never closed.
#
# WHAT IS CLAIMED. bin/lib/br/opt/extpark.sh defines the two hooks the tracer
# (bin/lib/br/opt/external.sh, BH-4667) and the lane's terminal guards call:
#   br_xpr_nopush   — a fork without maintainer edits: put the ext-nopush row
#                     FIRST, then one comment; a second tick is silent; an
#                     outage, a failed put or an unreadable push right posts
#                     nothing.
#   br_xpr_terminal — below the review cap the PR "waits for the next head"
#                     (rc 0, nothing posted); at the cap the ext-park row FIRST,
#                     one "Over to you, @<author>" comment, br_record
#                     external-parked, rc 3 with BR_XPR_PARKED=1. Never a
#                     close, an enqueue, an ABANDONED or an ALERTS line.
#
# X4 runs the REAL bin/blocked-resolver.sh tick over a scratch $HARNESS with the
# REAL external.sh and extpark.sh installed. X5 lifts br_fix_terminal,
# br_abandon and br_rebuild_fresh out of the same file (sourcing it runs a
# tick) and sources the real extpark.sh. Assertions are on the gh comment and
# PATCH logs, the attempts ledger, the state record and the lane log.
#
# Run from anywhere: tests/external-pr-handback.bh-4669-test.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

# ONE clock read for the whole file (bin/test-determinism-lint.sh).
NOW=$(date -u +%s)
ISO() { date -u -d "@$((NOW - ${1:-0}))" '+%Y-%m-%dT%H:%M:%SZ'; }

H="$T/h"
mkdir -p "$H/bin/lib" "$H/logs" "$H/state" "$H/flags" "$H/locks" "$H/env" "$H/builds" \
         "$H/state/merge-conductor" "$T/fakebin" "$T/repos" "$T/f"
cp "$DIR/bin/blocked-resolver.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/project-of.sh" \
   "$DIR/bin/box-for.sh" "$DIR/bin/alert-line.sh" "$H/bin/"
# shellcheck source=tests/lib/br-modules.sh
. "$DIR/tests/lib/br-modules.sh" || exit 1
br_modules_install "$DIR" "$H" || exit 1
# The lane's lib closure; the opt modules are each case's choice, so none stay.
scratch_install_closure bin/blocked-resolver.sh "$H" >/dev/null || exit 1
OPTD="$H/bin/lib/br/opt"; mkdir -p "$OPTD"; rm -f "$OPTD"/*
XMOD="$DIR/bin/lib/br/opt/external.sh"
chmod +x "$H/bin/"*.sh
# The harness's own git identity: a head authored as this is OURS, and quiet.
export GIT_CONFIG_GLOBAL="$T/gitconfig"
printf '[user]\n\tname = harness\n\temail = bot@harness.test\n' > "$GIT_CONFIG_GLOBAL"
export HARNESS_OPERATOR_LOGIN=operator
printf 'project-3 o/project-3 - - 2 box-project-3 100.0.0.9\nhproj o/hproj - - 2 box-h 100.0.0.8\n' > "$H/fleet.conf"
export FLEET_CONF="$H/fleet.conf"
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
mrs_fixture "$H" project-3 hproj
: > "$H/env/global.env"
for f in run-build.sh deploy-request.sh checks-run.sh pool-cap.sh beat.sh lane-alert.sh; do
  printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/side.txt"\nexit 0\n' "$T" > "$H/bin/$f"; chmod +x "$H/bin/$f"
done
# The jobs client: queue writes are RECORDED ("no enqueue" is an assertion about
# their absence), setting_get answers from $T/f/knob-<key>, and pr_attempts is
# $T/attempts.txt ("<repo> <num> <kind> <sha>" per row). $T/f/attempts-outage
# makes has/put/del answer rc 1, $T/f/put-fail fails a put, $T/f/del-fail a del.
cat > "$H/bin/jobs-client.sh" <<EOF
queue_put() { printf 'put %s\n' "\$*" >> "$T/queue.txt"; echo queued; }
queue_done() { printf 'done %s\n' "\$*" >> "$T/queue.txt"; return 0; }
queue_list() { return 1; }
setting_get() {
  local a; a=\$(cat "$T/f/knob-\$1" 2>/dev/null) || return 2
  case "\$a" in row:*) printf '%s' "\${a#row:}"; return 0 ;; outage) return 1 ;; *) return 2 ;; esac
}
pr_attempt_has() {
  [ -f "$T/f/attempts-outage" ] && return 1
  grep -qxF "\$1 \$2 \$3 \$4" "$T/attempts.txt" 2>/dev/null && return 0
  return 2
}
pr_attempt_put() {
  { [ -f "$T/f/attempts-outage" ] || [ -f "$T/f/put-fail" ]; } && return 1
  pr_attempt_has "\$@" && return 0
  printf '%s %s %s %s\n' "\$1" "\$2" "\$3" "\$4" >> "$T/attempts.txt"
}
pr_attempt_del() {
  { [ -f "$T/f/attempts-outage" ] || [ -f "$T/f/del-fail" ]; } && return 1
  pr_attempt_has "\$@" || return 2
  grep -vxF "\$1 \$2 \$3 \$4" "$T/attempts.txt" > "$T/attempts.tmp"; mv "$T/attempts.tmp" "$T/attempts.txt"
}
EOF
touch "$H/flags/fly-pool-project-3"

# ---------------------------------------------------------------------------
# Fixtures. pr-<n>.json is the REST PR object; the open list is all of them.
# PRADD <n> <head> <login> <draft> <upd-age-s> [head-repo|null] [fork] [mcm] [mergeable_state] [branch] [title]
PRADD() {
  jq -nc --argjson n "$1" --arg h "$2" --arg l "$3" --argjson d "$4" --arg u "$(ISO "$5")" \
        --arg hr "${6:-o/project-3}" --arg fk "${7:-false}" --arg mc "${8:-false}" --arg ms "${9:-clean}" \
        --arg br "${10:-feature/x$1}" --arg ti "${11:-Improve the layout}" \
    '{number:$n, html_url:("https://github.com/o/project-3/pull/"+($n|tostring)), state:"open",
      title:$ti, draft:$d, updated_at:$u, user:{login:$l, type:"User"},
      author_association:"NONE",
      head:{sha:$h, ref:$br, repo:(if $hr=="null" then null else {full_name:$hr, fork:($fk=="true")} end)},
      base:{ref:"main"}, merged_at:null, maintainer_can_modify:($mc=="true"), mergeable_state:$ms}' \
    > "$T/f/pr-$1.json"
  jq -s . "$T"/f/pr-*.json > "$T/f/list.json"
}
# REVADD <n> <state> <commit> <login> <assoc>
REVADD() {
  jq -nc --arg s "$2" --arg c "$3" --arg l "$4" --arg a "$5" \
    '{id:1, state:$s, commit_id:$c, user:{login:$l, type:"User"}, author_association:$a, body:"Please fix the null check."}' \
    >> "$T/f/revrows-$1"
  jq -s . "$T/f/revrows-$1" > "$T/f/reviews-$1.json"
}
# COMMIT <sha> <age-s> <author-email>
COMMIT() {
  jq -nc --arg d "$(ISO "$2")" --arg e "$3" '{sha:"x", commit:{committer:{date:$d}, author:{email:$e}}}' \
    > "$T/f/commit-$1.json"
}
KNOB() { if [ "$2" = none ]; then rm -f "$T/f/knob-$1"; else printf '%s' "$2" > "$T/f/knob-$1"; fi; }
RESET() { rm -rf "$T/f"/* "$T"/comment-body-* "$H/state/blocked-resolver" "$OPTD"/* "$H/logs/blocked-resolver.log" \
                 "$H/state/merge-conductor/"* "${TMPDIR:-/tmp}"/br-open-prs.* 2>/dev/null
          mkdir -p "$T/f"; echo '[]' > "$T/f/list.json"
          : > "$T/gh.txt"; : > "$T/patch.txt"; : > "$T/comments.txt"; : > "$T/push.txt"
          : > "$T/queue.txt"; : > "$T/hooks.txt"; : > "$T/attempts.txt"; : > "$T/side.txt"; : > "$T/run.log"
          printf '%s\n' '{"resources":{"core":{"remaining":4000,"limit":5000,"reset":0},"graphql":{"remaining":4000,"limit":5000,"reset":0}}}' > "$T/f/ratelimit.json"; }
export GH_BUDGET_TTL_S=0

H1=1111111111111111111111111111111111111111
H2=2222222222222222222222222222222222222222

cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh.txt"
F="$T/f"
send() { printf 'HTTP/2 %s\r\nserver: x\r\n\r\n%s' "\$1" "\$2"; }
case "\$1 \$2" in
  "api rate_limit") cat "\$F/ratelimit.json"; exit 0 ;;
esac
if [ "\$1" = api ] && [ "\$2" = -i ] && [ "\$3" = -X ]; then
  M="\$4"; P="\$5"
  case "\$M \$P" in
    "PATCH repos/"*"/pulls/"*)
      printf '%s\n' "\$*" >> "$T/patch.txt"; touch "\$F/closed-\${P##*/}"; send 200 '{"state":"closed"}' ;;
    "POST repos/"*"/comments")
      [ -f "\$F/comment-fail" ] && { send 500 '{"message":"Server Error"}'; exit 0; }
      printf '%s\n' "\$*" >> "$T/comments.txt"
      for a in "\$@"; do case "\$a" in body=@*) cp "\${a#body=@}" "$T/comment-body-\$(grep -c . "$T/comments.txt")" ;; esac; done
      send 201 '{"id":1}' ;;
    "GET repos/o/project-3/pulls")
      [ -f "\$F/list-fail" ] && { send 403 '{"message":"API rate limit exceeded"}'; exit 0; }
      send 200 "\$(cat "\$F/list.json")" ;;
    "GET repos/o/project-3/pulls/"*"/reviews"*)
      N=\${P#repos/o/project-3/pulls/}; N=\${N%%/*}
      send 200 "\$(cat "\$F/reviews-\$N.json" 2>/dev/null || echo '[]')" ;;
    "GET repos/o/project-3/pulls/"*)
      N=\${P##*/}
      [ -f "\$F/prfail-\$N" ] && { send 403 '{"message":"API rate limit exceeded"}'; exit 0; }
      if [ -f "\$F/prfail2-\$N" ]; then
        echo x >> "\$F/prcount-\$N"
        [ "\$(grep -c . "\$F/prcount-\$N")" -ge 2 ] && { send 403 '{"message":"API rate limit exceeded"}'; exit 0; }
      fi
      [ -f "\$F/pr-\$N.json" ] || { send 404 '{"message":"Not Found"}'; exit 0; }
      if [ -f "\$F/closed-\$N" ]; then send 200 "\$(jq -c '.state="closed"' "\$F/pr-\$N.json")"
      else send 200 "\$(cat "\$F/pr-\$N.json")"; fi ;;
    "GET repos/o/project-3/commits/"*)
      S=\${P##*/}
      if [ -f "\$F/commit-\$S.json" ]; then send 200 "\$(cat "\$F/commit-\$S.json")"; else send 404 '{"message":"Not Found"}'; fi ;;
    "GET repos/o/hproj/pulls") send 200 '[]' ;;
    *) send 200 '[]' ;;
  esac
  exit 0
fi
echo ""
exit 0
EOF
chmod +x "$T/fakebin/gh"
# Every push is recorded: "this child pushes nothing" is asserted on it.
REALGIT=$(command -v git)
printf '#!/bin/bash\ncase "$1" in push) printf "%%s\\n" "$*" >> "%s/push.txt"; exit 0 ;; esac\nexec "%s" "$@"\n' \
  "$T" "$REALGIT" > "$T/fakebin/git"
chmod +x "$T/fakebin/git"
export PATH="$T/fakebin:$PATH"
export GH_TOKEN=""

RC=0
RUN() { RC=0
        ( HARNESS="$H" FLEET_CONF="$H/fleet.conf" REPOS_ROOT="$T/repos" \
           env ${BRENV[*]:+"${BRENV[@]}"} \
           bash "$H/bin/blocked-resolver.sh" project-3 >>"$T/run.log" 2>&1 ) || RC=$?; }
BRENV=()
LOG() { cat "$H/logs/blocked-resolver.log" 2>/dev/null; }
HAS() { grep -qF -- "$1" "$H/logs/blocked-resolver.log" 2>/dev/null; }
NPATCH() { grep -c . "$T/patch.txt"; }
NCOMM() { grep -c . "$T/comments.txt"; }
NPUSH() { grep -c . "$T/push.txt"; }
REC() { cat "$H/state/blocked-resolver/project-3/$1.json" 2>/dev/null; }
XINSTALL() { cp "$XMOD" "$OPTD/external.sh"; }
# A canary extfix/extrebase that records argv and what the gate exported.
CANARY_HOOKS() {
  cat > "$OPTD/extfix.sh" <<EOF
br_xpr_fix() { printf 'fix|%s|%s|head=%s|num=%s|author=%s\n' "\$#" "\$*" "\${BR_XPR_HEAD:-}" "\${BR_XPR_NUM:-}" "\${BR_XPR_AUTHOR:-}" >> "$T/hooks.txt"; return 3; }
EOF
  cat > "$OPTD/extrebase.sh" <<EOF
br_xpr_rebase() { printf 'rebase|%s|%s\n' "\$#" "\$*" >> "$T/hooks.txt"; return 3; }
EOF
}
# The standard tracer: outsider collaborator-1's PR #7, a lead CHANGES_REQUESTED on H1.
TRACER() { # TRACER <commit-age-s> [email]
  PRADD 7 "$H1" collaborator-1 false 300
  REVADD 7 CHANGES_REQUESTED "$H1" operator OWNER
  COMMIT "$H1" "$1" "${2:-collaborator-1@example.com}"
}
ROW7='https://github.com/o/project-3/pull/7'
PMOD="$DIR/bin/lib/br/opt/extpark.sh"
[ -r "$PMOD" ] && ok || bad "bin/lib/br/opt/extpark.sh does not exist"
PINSTALL() { cp "$XMOD" "$OPTD/external.sh"; cp "$PMOD" "$OPTD/extpark.sh" 2>/dev/null; CANARY_HOOKS; }
NROWS() { grep -c . "$T/attempts.txt"; }
NOPUSH_PR() { # NOPUSH_PR [head-repo] — collaborator-1's fork, maintainer edits OFF
  PRADD 7 "$H1" collaborator-1 false 300 "${1:-collaborator-1/project-3}" true false
  REVADD 7 CHANGES_REQUESTED "$H1" operator OWNER; COMMIT "$H1" 3660 y@example.com
}
NOALERTS() { [ ! -s "$H/logs/ALERTS.log" ]; }

# ===========================================================================
# X4: br_xpr_nopush, through the real lane tick.
# ===========================================================================
RESET; PINSTALL; KNOB external_pr.fix_rounds.project-3 row:1; NOPUSH_PR
RUN
[ "$RC" = 0 ] && ok || bad "X4a: the tick must exit 0 (rc $RC): $(tail -3 "$T/run.log")"
[ "$(NCOMM)" = 1 ] && grep -q 'POST repos/o/project-3/issues/7/comments' "$T/comments.txt" && ok \
  || bad "X4a: exactly one comment must be POSTed to #7 (comments=$(NCOMM)): $(cat "$T/comments.txt") $(LOG | tail -4)"
grep -qF "can't push to this branch" "$T"/comment-body-* 2>/dev/null && ok \
  || bad "X4a: the comment must say the harness can't push to this branch: $(cat "$T"/comment-body-* 2>/dev/null)"
[ "$(cat "$T/attempts.txt")" = "o/project-3 7 ext-nopush $H1" ] && ok \
  || bad "X4a: attempts must hold exactly 'o/project-3 7 ext-nopush H1': $(cat "$T/attempts.txt")"
[ ! -s "$T/hooks.txt" ] && [ "$(NPUSH)" = 0 ] && [ "$(NPATCH)" = 0 ] && ! HAS worktree && ok \
  || bad "X4a: no agent call, no push, no close, no worktree (hooks=$(cat "$T/hooks.txt") push=$(NPUSH) patch=$(NPATCH))"
[ ! -s "$T/queue.txt" ] && NOALERTS && ok || bad "X4a: no enqueue and no ALERTS line: $(cat "$T/queue.txt")"
# X4b: the second tick on the same head is silent.
RUN
[ "$(NCOMM)" = 1 ] && [ "$(NROWS)" = 1 ] && ok || bad "X4b: a second tick must post nothing (comments=$(NCOMM) rows=$(NROWS))"
HAS "external o/project-3#7: already told the author on ${H1:0:12}" && ok \
  || bad "X4b: the second tick must log 'already told the author': $(LOG | tail -3)"
# A new head is told once more (once per head).
PRADD 7 "$H2" collaborator-1 false 300 collaborator-1/project-3 true false; REVADD 7 CHANGES_REQUESTED "$H2" operator OWNER
COMMIT "$H2" 3660 y@example.com
RUN
[ "$(NCOMM)" = 2 ] && grep -qxF "o/project-3 7 ext-nopush $H2" "$T/attempts.txt" && ok \
  || bad "X4b+: a new head gets one more notice (comments=$(NCOMM)): $(cat "$T/attempts.txt")"

# X4a': a CONTRIBUTOR on the same fork shape gets the same answer.
RESET; PINSTALL; KNOB external_pr.fix_rounds.project-3 row:1; NOPUSH_PR
jq -c '.author_association="CONTRIBUTOR"' "$T/f/pr-7.json" > "$T/f/pr7.tmp" && mv "$T/f/pr7.tmp" "$T/f/pr-7.json"
jq -s . "$T"/f/pr-*.json > "$T/f/list.json"
RUN
[ "$(NCOMM)" = 1 ] && [ "$(cat "$T/attempts.txt")" = "o/project-3 7 ext-nopush $H1" ] && [ ! -s "$T/hooks.txt" ] && ok \
  || bad "X4a': a CONTRIBUTOR's no-push fork gets one notice and one row (comments=$(NCOMM)): $(cat "$T/attempts.txt")"

# X4c: the head repo is null — the push right is unreadable: nothing at all.
RESET; PINSTALL; KNOB external_pr.fix_rounds.project-3 row:1; NOPUSH_PR null
RUN
[ "$(NCOMM)" = 0 ] && [ "$(NROWS)" = 0 ] && HAS "push right unreadable" && ok \
  || bad "X4c: an unreadable push right writes no row and posts nothing (comments=$(NCOMM) rows=$(NROWS))"
# X4d: an attempts outage is never a miss.
RESET; PINSTALL; KNOB external_pr.fix_rounds.project-3 row:1; NOPUSH_PR; touch "$T/f/attempts-outage"
RUN
[ "$(NCOMM)" = 0 ] && [ "$(NROWS)" = 0 ] && HAS "the attempts ledger would not read (rc 1)" && ok \
  || bad "X4d: an outage posts nothing (comments=$(NCOMM) rows=$(NROWS)): $(LOG | tail -3)"
# X4e: a failed put posts nothing.
RESET; PINSTALL; KNOB external_pr.fix_rounds.project-3 row:1; NOPUSH_PR; touch "$T/f/put-fail"
RUN
[ "$(NCOMM)" = 0 ] && [ "$(NROWS)" = 0 ] && HAS "the ext-nopush row on ${H1:0:12} was not written" && ok \
  || bad "X4e: a failed put posts nothing (comments=$(NCOMM) rows=$(NROWS)): $(LOG | tail -3)"
# X4f: the comment fails after the put — the row is released for the next tick.
RESET; PINSTALL; KNOB external_pr.fix_rounds.project-3 row:1; NOPUSH_PR; touch "$T/f/comment-fail"
RUN
[ "$(NCOMM)" = 0 ] && [ "$(NROWS)" = 0 ] && HAS "the ext-nopush row on ${H1:0:12} was released" && ok \
  || bad "X4f: a failed comment releases its row (rows=$(NROWS)): $(LOG | tail -3)"
rm -f "$T/f/comment-fail"; RUN
[ "$(NCOMM)" = 1 ] && [ "$(NROWS)" = 1 ] && ok || bad "X4f: the next tick retries and posts once (comments=$(NCOMM) rows=$(NROWS))"
# ...and when the release fails too, one honest line and that head stays silent.
RESET; PINSTALL; KNOB external_pr.fix_rounds.project-3 row:1; NOPUSH_PR; touch "$T/f/comment-fail" "$T/f/del-fail"
RUN
HAS "told nobody, and the ext-nopush row on ${H1:0:12} could not be released — this head stays silent" && [ "$(NROWS)" = 1 ] && ok \
  || bad "X4f: a failed release must say so: $(LOG | tail -3)"

# ===========================================================================
# X5: br_xpr_terminal through the lane's real terminals, lifted.
# ===========================================================================
# BH-5241: the corpus is the driver plus bin/lib/br/*.sh (tests/lib/br-corpus.sh),
# because the record functions moved out of the driver into bin/lib/br/record.sh.
# shellcheck source=tests/lib/br-corpus.sh
. "$DIR/tests/lib/br-corpus.sh" || exit 1
br_corpus "$H" "$T/br-corpus.sh" || exit 1
: > "$T/lift.sh"
for fn in br_rkey br_cap_key br_file br_load br_save br_num br_rows_count br_cap_rows br_record br_fix_cap br_shape \
          br_is_external br_fix_terminal br_fix_terminal_word br_abandon br_xpr_parked br_rebuild_fresh \
          br_slug_of_url br_pr_comment; do
  awk -v f="^$fn\\\\(\\\\)" '
    $0 ~ f { p=1; if ($0 ~ /\}$/ && $0 !~ /\{ *$/) { print; exit } }
    p { print } p && /^}$/ { exit }' "$T/br-corpus.sh" >> "$T/lift.sh"
done
for fn in br_fix_terminal br_abandon br_rebuild_fresh br_record br_fix_cap br_cap_rows br_xpr_parked; do
  grep -q "^$fn()" "$T/lift.sh" && ok || bad "lift: $fn() was not found in bin/blocked-resolver.sh"
done
LRC=0
# LIFT <with-extpark:1|0> <fn> [args...] — rc in LRC, BR_XPR_PARKED in $T/parked.
LIFT() {
  LRC=0
  ( export HARNESS="$H" LOG="$H/logs/blocked-resolver.log" ST="$H/state/blocked-resolver" H OBSERVE=0
    say() { echo "$*" >> "$LOG"; }
    STAMP() { echo t; }
    . "$H/bin/lib/gh-rest.sh"; . "$H/bin/lib/gh-pr-list.sh"
    . "$H/bin/lib/merge-conductor-lib.sh" >/dev/null 2>&1
    . "$H/bin/jobs-client.sh"
    . "$T/lift.sh"
    BR_XPR_PARKED=0
    [ "$1" = 1 ] && { . "$PMOD" || exit 99; }
    if [ "$1" = spy ]; then
      br_xpr_terminal() { echo "HOOK $*" >> "$T/x5.txt"; return 3; }
      br_abandon() { echo "ABANDON $*" >> "$T/x5.txt"; }
      br_rebuild_fresh() { echo "REBUILD $*" >> "$T/x5.txt"; }
    fi
    br_review_cleared() { return 1; }
    br_close_pr() { echo "CLOSE $*" >> "$T/x5.txt"; return 0; }
    br_event() { :; }
    shift; xrc=0; "$@" || xrc=$?
    echo "$BR_XPR_PARKED" > "$T/parked"; exit "$xrc" ) || LRC=$?
}
REC7() { cat "$H/state/blocked-resolver/project-3/o-project-3-7.json" 2>/dev/null; }
SEED7() { mkdir -p "$H/state/blocked-resolver/project-3"
          printf '{"external":"true","fixrounds":%s,"attempts":[]}\n' "$1" > "$H/state/blocked-resolver/project-3/o-project-3-7.json"; }
X5RESET() { RESET; : > "$T/x5.txt"; : > "$T/parked"; rm -f "$H/logs/ALERTS.log"; unset BR_REVIEW_FIX_ROUNDS
            PRADD 7 "$H1" collaborator-1 false 300 collaborator-1/project-3 true true; }

# X5a: at the cap (2 of 2), one hand-back, the row first, external-parked recorded.
X5RESET; SEED7 2
LIFT 1 br_fix_terminal project-3 o-project-3-7 review-changes-requested "$ROW7" - -
[ "$LRC" = 3 ] && [ "$(cat "$T/parked")" = 1 ] && ok || bad "X5a: at the cap the terminal answers rc 3 with BR_XPR_PARKED=1 (rc $LRC parked=$(cat "$T/parked")): $(LOG | tail -3)"
[ "$(NCOMM)" = 1 ] && grep -q '^Over to you, @collaborator-1\.' "$T"/comment-body-* 2>/dev/null && ok \
  || bad "X5a: one comment starting 'Over to you, @collaborator-1' (comments=$(NCOMM)): $(cat "$T"/comment-body-* 2>/dev/null)"
grep -qF 'ran 2 fix round(s)' "$T"/comment-body-* 2>/dev/null && ok || bad "X5a: the comment names the rounds run: $(cat "$T"/comment-body-* 2>/dev/null)"
[ "$(cat "$T/attempts.txt")" = "o/project-3 7 ext-park $H1" ] && ok || bad "X5a: attempts must hold exactly 'o/project-3 7 ext-park H1': $(cat "$T/attempts.txt")"
[ "$(REC7 | jq -r '.attempts[-1].action')" = external-parked ] \
  && REC7 | jq -e --arg u "$ROW7" '.attempts[-1].url == $u and (.attempts[-1].detail | test("handed back to @collaborator-1 on 111111111111 after 2 of 2"))' >/dev/null && ok \
  || bad "X5a: the record's last attempt must be external-parked with the PR url: $(REC7)"
# X5b: the second call on the same head posts nothing and writes nothing.
LIFT 1 br_fix_terminal project-3 o-project-3-7 review-changes-requested "$ROW7" - -
[ "$LRC" = 3 ] && [ "$(NCOMM)" = 1 ] && [ "$(NROWS)" = 1 ] && [ "$(REC7 | jq '.attempts | length')" = 1 ] && ok \
  || bad "X5b: a second call is silent (rc $LRC comments=$(NCOMM) rows=$(NROWS) attempts=$(REC7 | jq '.attempts|length'))"
HAS "already handed to @collaborator-1 on ${H1:0:12}" && ok || bad "X5b: the second call logs 'already handed to': $(LOG | tail -2)"
X5D_PATCH=$(NPATCH); X5D_Q=$(grep -c . "$T/queue.txt"); X5D_OUT=$(REC7 | jq -r '.outcome // ""'); X5D_X=$(cat "$T/x5.txt")

# X5c: below the cap (1 of 2): waits for the next head, nothing posted, rc 0 —
# and PARKED (TEST-CHANGE, review of 7239e2ec: br_one checks BR_XPR_PARKED, not
# the rc, so an unparked rc 0 spent a PER_TICK slot and released the
# conductor's park every tick while nothing changed).
X5RESET; SEED7 1
LIFT 1 br_fix_terminal project-3 o-project-3-7 review-changes-requested "$ROW7" - -
[ "$LRC" = 0 ] && [ "$(NCOMM)" = 0 ] && [ "$(NROWS)" = 0 ] && [ "$(cat "$T/parked")" = 1 ] && ok \
  || bad "X5c: below the cap rc 0, nothing posted, parked (rc $LRC comments=$(NCOMM) rows=$(NROWS) parked=$(cat "$T/parked"))"
HAS "project-3/o-project-3-7 [review-changes-requested]: external PR $ROW7 — round 1 of 2 spent; waits for the next head, nothing closed" && ok \
  || bad "X5c: below the cap the log says it waits for the next head: $(LOG | tail -2)"
# The cap is BR_REVIEW_FIX_ROUNDS: raised to 3, two rounds still wait.
X5RESET; SEED7 2
BR_REVIEW_FIX_ROUNDS=3 LIFT 1 br_fix_terminal project-3 o-project-3-7 review-changes-requested "$ROW7" - -
[ "$LRC" = 0 ] && [ "$(NCOMM)" = 0 ] && HAS "round 2 of 3 spent" && ok || bad "X5c: the cap reads BR_REVIEW_FIX_ROUNDS (rc $LRC): $(LOG | tail -2)"

# X5d: across X5a-c — no close, no enqueue, no outcome, no ALERTS line.
[ "$X5D_PATCH" = 0 ] && [ "$(NPATCH)" = 0 ] && [ "$X5D_Q" = 0 ] && [ -z "$X5D_OUT" ] && [ -z "$X5D_X" ] && NOALERTS && ok \
  || bad "X5d: never a close, an enqueue, an outcome or an ALERTS line (patch=$X5D_PATCH queue=$X5D_Q outcome=$X5D_OUT x=$X5D_X)"

# X5e: br_abandon's arg shape ($6 a sentence) at the cap: rc 3, no ABANDONED, one comment;
# the same head again is silent; a fresh head gets exactly one more.
X5RESET; SEED7 2
LIFT 1 br_abandon project-3 o-project-3-7 ci-failing "$ROW7" - "why sentence" -
[ "$LRC" = 3 ] && [ "$(NCOMM)" = 1 ] && [ "$(REC7 | jq -r '.outcome // ""')" = "" ] && ! HAS ABANDONED && ok \
  || bad "X5e: br_abandon at the cap answers rc 3, one comment, no ABANDONED (rc $LRC comments=$(NCOMM)): $(REC7)"
LIFT 1 br_abandon project-3 o-project-3-7 ci-failing "$ROW7" - "why sentence" -
[ "$LRC" = 3 ] && [ "$(NCOMM)" = 1 ] && ok || bad "X5e: the same head is silent through br_abandon (rc $LRC comments=$(NCOMM))"
PRADD 7 "$H2" collaborator-1 false 300 collaborator-1/project-3 true true
LIFT 1 br_abandon project-3 o-project-3-7 ci-failing "$ROW7" - "why sentence" -
[ "$LRC" = 3 ] && [ "$(NCOMM)" = 2 ] && grep -qxF "o/project-3 7 ext-park $H2" "$T/attempts.txt" && ok \
  || bad "X5e: a fresh head gets exactly one more park comment (rc $LRC comments=$(NCOMM)): $(cat "$T/attempts.txt")"
# Below the cap br_abandon still never answers 0 (cirepair reads 0 as closed).
X5RESET; SEED7 0
LIFT 1 br_abandon project-3 o-project-3-7 ci-failing "$ROW7" - "why sentence" -
[ "$LRC" = 3 ] && [ "$(NCOMM)" = 0 ] && ok || bad "X5e: br_abandon below the cap is rc 3, nothing posted (rc $LRC comments=$(NCOMM))"
# X5f (review of 7239e2ec): br_rebuild_fresh BELOW the cap — the direct callers
# (rebuild-fresh, rebuild-review-blocked) reach it with no fix round run, so
# fixrounds never grows. It must park: rc 0, nothing posted, BR_XPR_PARKED=1.
X5RESET; SEED7 0
LIFT 1 br_rebuild_fresh project-3 o-project-3-7 build-dead "$ROW7" - -
[ "$LRC" = 0 ] && [ "$(NCOMM)" = 0 ] && [ "$(cat "$T/parked")" = 1 ] && [ "$(NPATCH)" = 0 ] && [ ! -s "$T/queue.txt" ] && ok \
  || bad "X5f: br_rebuild_fresh below the cap must park (rc $LRC comments=$(NCOMM) parked=$(cat "$T/parked") patch=$(NPATCH))"
# ...and br_one spends no slot and releases no park on that flag: its parked
# return sits before the TICK_DONE write and the conductor hand-off release.
awk '/^br_one\(\) *\{/ {on=1} on && /BR_XPR_PARKED:-0\}" = 1 \]; then br_reset_token; return 3/ && !p {p=NR} on && />> "\$TICK_DONE"/ && !t {t=NR} on && /mc_handoff_release "/ && !h {h=NR} on && /^}/ {exit} END {exit !(p && t && h && p < t && p < h)}' "$DIR/bin/blocked-resolver.sh" \
  && ok || bad "X5f: br_one must return on BR_XPR_PARKED before TICK_DONE and the hand-off release"
# br_rebuild_fresh's arg shape reaches the same hook.
X5RESET; SEED7 2
LIFT 1 br_rebuild_fresh project-3 o-project-3-7 build-dead "$ROW7" - -
[ "$LRC" = 3 ] && [ "$(NCOMM)" = 1 ] && [ "$(NPATCH)" = 0 ] && [ ! -s "$T/queue.txt" ] && ok \
  || bad "X5e: br_rebuild_fresh at the cap hands back, never closes or enqueues (rc $LRC comments=$(NCOMM) patch=$(NPATCH))"

# X5f: the put lands, the comment fails: the row is deleted, nothing recorded.
X5RESET; SEED7 2; touch "$T/f/comment-fail"
LIFT 1 br_fix_terminal project-3 o-project-3-7 review-changes-requested "$ROW7" - -
[ "$LRC" = 3 ] && [ "$(NROWS)" = 0 ] && [ "$(REC7 | jq '.attempts | length')" = 0 ] && HAS "the ext-park row on ${H1:0:12} was released" && ok \
  || bad "X5f: a failed comment releases the row and records nothing (rc $LRC rows=$(NROWS)): $(REC7) $(LOG | tail -2)"
# An outage, a failed put, a closed PR and an unreadable PR post nothing and write nothing.
for sw in attempts-outage put-fail closed-7 prfail-7; do
  X5RESET; SEED7 2; touch "$T/f/$sw"
  LIFT 1 br_fix_terminal project-3 o-project-3-7 review-changes-requested "$ROW7" - -
  [ "$LRC" = 3 ] && [ "$(NCOMM)" = 0 ] && [ "$(NROWS)" = 0 ] && [ "$(REC7 | jq '.attempts | length')" = 0 ] \
    && [ "$(cat "$T/parked")" = 1 ] && ok \
    || bad "X5 $sw: nothing posted or written, parked (rc $LRC comments=$(NCOMM) rows=$(NROWS)): $(LOG | tail -2)"
done

# N1: an unstamped review-changes-requested record at the cap never reaches the hook.
X5RESET; mkdir -p "$H/state/blocked-resolver/project-3"
printf '{"fixrounds":2,"attempts":[]}\n' > "$H/state/blocked-resolver/project-3/o-project-3-7.json"
LIFT spy br_fix_terminal project-3 o-project-3-7 review-changes-requested "$ROW7" - -
! grep -q '^HOOK' "$T/x5.txt" && grep -q '^ABANDON project-3 o-project-3-7 review-changes-requested' "$T/x5.txt" && ok \
  || bad "N1: a harness PR must reach br_abandon and never br_xpr_terminal: $(cat "$T/x5.txt")"
# ...and the spy is live: the same call on a stamped record does reach it.
SEED7 2; : > "$T/x5.txt"
LIFT spy br_fix_terminal project-3 o-project-3-7 review-changes-requested "$ROW7" - -
grep -q "^HOOK project-3 o-project-3-7 review-changes-requested $ROW7" "$T/x5.txt" && ok || bad "N1: the spy must see a stamped record: $(cat "$T/x5.txt")"

echo "external-pr-handback.bh-4669: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
