#!/bin/bash
# tests/external-pr-source.bh-4667-test.sh — BH-4664.0 (BH-4667): the external
# PR source, the shared gates, and the never-close belt.
#
# WHAT IS CLAIMED. A third party's open PR on an opted-in project becomes ONE
# `xreviews` candidate when its head carries a standing CHANGES_REQUESTED (or it
# went dirty); br_one runs it through bin/lib/br/opt/external.sh's gates — the
# knob, the push right, the author-quiet window — and hands it to a sibling's
# hook, or says `no handler installed` and spends nothing. And whatever reaches
# the lane's terminals, an external PR is never closed, rebuilt or abandoned,
# with every external module missing too.
#
# The REAL bin/blocked-resolver.sh runs a tick over a scratch $HARNESS with a
# fake `gh` that answers the REST envelope from files and records every call.
# The assertions are on the lane's log, the gh call log (PATCH, comment POST),
# the recorded hook argv and the state record — never on the source text.
# The belt's per-function cases lift the functions out of the same file, the
# way tests/blocked-resolver-rest.bh-783-test.sh does: sourcing it runs a tick.
#
# Run from anywhere: tests/external-pr-source.bh-4667-test.sh   (exit 0 = pass)
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
scratch_install_closure bin/blocked-resolver.sh "$H" >/dev/null || exit 1
OPTD="$H/bin/lib/br/opt"; mkdir -p "$OPTD"
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
# their absence), and setting_get answers from $T/f/knob-<key>: `row:<v>`,
# `outage`, or nothing at all (no row).
cat > "$H/bin/jobs-client.sh" <<EOF
queue_put() { printf 'put %s\n' "\$*" >> "$T/queue.txt"; echo queued; }
queue_done() { printf 'done %s\n' "\$*" >> "$T/queue.txt"; return 0; }
queue_list() { return 1; }
setting_get() {
  local a; a=\$(cat "$T/f/knob-\$1" 2>/dev/null) || return 2
  case "\$a" in row:*) printf '%s' "\${a#row:}"; return 0 ;; outage) return 1 ;; *) return 2 ;; esac
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
RESET() { rm -rf "$T/f"/* "$H/state/blocked-resolver" "$OPTD"/* "$H/logs/blocked-resolver.log" \
                 "$H/state/merge-conductor/"* "${TMPDIR:-/tmp}"/br-open-prs.* 2>/dev/null
          mkdir -p "$T/f"; echo '[]' > "$T/f/list.json"
          : > "$T/gh.txt"; : > "$T/patch.txt"; : > "$T/comments.txt"; : > "$T/push.txt"
          : > "$T/queue.txt"; : > "$T/hooks.txt"; : > "$T/side.txt"; : > "$T/run.log"
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
      printf '%s\n' "\$*" >> "$T/comments.txt"; send 201 '{"id":1}' ;;
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

# ===========================================================================
# Observable outcome: a real tick, br_candidates -> br_one, on the tracer.
# ===========================================================================
RESET; XINSTALL; KNOB external_pr.fix_rounds.project-3 row:1; TRACER 600
RUN
[ "$RC" = 0 ] && ok || bad "OO: the tick must exit 0 (rc $RC): $(tail -3 "$T/run.log")"
HAS "AUTHOR_ACTIVE o/project-3#7 head=11111111 committed 10m ago (quiet window 60m) — retried next tick" && ok \
  || bad "OO: a head committed 10 min ago must log AUTHOR_ACTIVE: $(LOG | tail -5)"
HAS "project-3/o-project-3-7 [external-changes-requested]: external PR $ROW7 — the shared gates" && ok \
  || bad "OO: the external-changes-requested candidate must reach br_one: $(LOG | tail -3)"
[ "$(NPATCH)" = 0 ] && [ "$(NCOMM)" = 0 ] && [ "$(NPUSH)" = 0 ] && ok \
  || bad "OO: nothing may be written on the PR (patch=$(NPATCH) comments=$(NCOMM) push=$(NPUSH))"
# X1a: the refusal wrote no record at all.
[ -z "$(REC o-project-3-7)" ] && ok || bad "X1a: a refused gate must write no record: $(REC o-project-3-7)"
# X10: no ticket key was derived for the outsider's row.
HAS "discovery carried no ticket key" && bad "X10: an external row must never derive a ticket key" || ok

# 61 minutes: the gate passes and, with no hook installed, says so.
RESET; XINSTALL; KNOB external_pr.fix_rounds.project-3 row:1; TRACER 3660
RUN
HAS "external external-changes-requested o/project-3#7: no handler installed" && ok \
  || bad "OO/X9b: past the quiet window with no hook, the lane must say 'no handler installed': $(LOG | tail -5)"
[ "$(NPATCH)" = 0 ] && [ "$(NCOMM)" = 0 ] && [ "$(NPUSH)" = 0 ] && ok \
  || bad "OO: no handler means no write (patch=$(NPATCH) comments=$(NCOMM) push=$(NPUSH))"
[ "$(REC o-project-3-7 | jq -r '.external // ""')" = true ] && ok \
  || bad "the gate that passed must stamp the record external=true on the PR's rkey: $(REC o-project-3-7)"

# X1b: 61 minutes, a canary extfix: the hook is called once with six args and the head.
RESET; XINSTALL; CANARY_HOOKS; KNOB external_pr.fix_rounds.project-3 row:1; TRACER 3660
RUN
[ "$(grep -c '^fix|' "$T/hooks.txt")" = 1 ] && ok || bad "X1b: br_xpr_fix must be called exactly once: $(cat "$T/hooks.txt")"
[ "$(cut -d'|' -f2 "$T/hooks.txt")" = 6 ] && ok || bad "X1b: the hook takes the six br_one args: $(cat "$T/hooks.txt")"
grep -qF "|project-3 o-project-3-7 external-changes-requested $ROW7 - -|head=$H1|num=7|author=collaborator-1" "$T/hooks.txt" && ok \
  || bad "X1b: argv and the exported head/num/author must reach the hook: $(cat "$T/hooks.txt")"

# X1c: 10 minutes, but the head is authored as the harness: quiet.
RESET; XINSTALL; CANARY_HOOKS; KNOB external_pr.fix_rounds.project-3 row:1; TRACER 600 bot@harness.test
RUN
[ "$(grep -c '^fix|' "$T/hooks.txt")" = 1 ] && ok || bad "X1c: a head authored as GI_EMAIL is quiet — the hook must run: $(LOG | tail -3)"
HAS AUTHOR_ACTIVE && bad "X1c: a harness-authored head must not read AUTHOR_ACTIVE" || ok

# ===========================================================================
# X2: the knob. Off, absent and an outage give no row; 1 gives one.
# ===========================================================================
x2() { # x2 <knob> <env-value|-> <want-rows> <want-src|->
  RESET; XINSTALL; TRACER 600; KNOB external_pr.fix_rounds.project-3 "$1"
  BRENV=(); [ "$2" = - ] || BRENV=("EXTERNAL_PR_FIX_ROUNDS=$2")
  RUN; BRENV=()
  local n; n=$(LOG | grep -c 'AUTHOR_ACTIVE o/project-3#7')
  [ "$n" = "$3" ] && ok || bad "X2 knob=$1 env=$2: want $3 external row(s) reaching the gate, got $n: $(LOG | tail -3)"
  [ "$4" = - ] || { HAS "external fix rounds off for project-3 ($4)" && ok \
    || bad "X2 knob=$1 env=$2: want 'external fix rounds off for project-3 ($4)': $(LOG | tail -3)"; }
}
x2 none   -  0 default
x2 row:0  -  0 setting
x2 outage 1  0 outage
x2 none   1  1 -
x2 row:1  -  1 -
# Exactly one row: the candidate TSV from the source itself.
RESET; XINSTALL; TRACER 600; KNOB external_pr.fix_rounds.project-3 row:1
# BH-5241: the corpus is the driver plus bin/lib/br/*.sh (tests/lib/br-corpus.sh),
# because the record functions moved out of the driver into bin/lib/br/record.sh.
# shellcheck source=tests/lib/br-corpus.sh
. "$DIR/tests/lib/br-corpus.sh" || exit 1
br_corpus "$H" "$T/br-corpus.sh" || exit 1
ROWS_OUT=$( export HARNESS="$H" LOG="$T/src.log" H ST="$H/state/blocked-resolver" ONLY=project-3
  say() { echo "$*" >> "$T/src.log"; }
  . "$H/bin/lib/gh-rest.sh"; . "$H/bin/lib/gh-pr-list.sh"; . "$H/bin/jobs-client.sh"
  . "$H/bin/lib/merge-conductor-lib.sh" >/dev/null 2>&1
  br_use_token() { :; }; br_reset_token() { :; }
  for fn in br_rkey br_review_rows br_lead_pick br_lead_merges_only br_review_harness_pick br_review_newest br_review_verdict; do
    awk -v f="^$fn\\\\(\\\\)" '$0 ~ f {p=1} p{print} p&&/^}$/{exit} p&&/}$/&&/\(\) *\{.*\}$/{exit}' "$T/br-corpus.sh"
  done > "$T/srcfns.sh"
  BR_LEAD_HDR='LEAD FINDINGS — every item must be addressed in code'
  BR_REVIEW_FOOTER='_Automated harness review (Fable) of '
  . "$T/srcfns.sh"; . "$XMOD"
  br_opt_external_candidates )
[ "$(printf '%s\n' "$ROWS_OUT" | grep -c .)" = 1 ] \
  && [ "$ROWS_OUT" = "$(printf 'xreviews\tproject-3\to-project-3-7\texternal-changes-requested\t%s\t-\t-\t-' "$ROW7")" ] && ok \
  || bad "X2: knob 1 must give exactly one xreviews row with ticket key '-': [$ROWS_OUT] $(cat "$T/src.log" 2>/dev/null | tail -3)"

# ===========================================================================
# X11: drafts and our own PRs are never external; an APPROVE is no row; dirty is.
# ===========================================================================
RESET; XINSTALL; CANARY_HOOKS; KNOB external_pr.fix_rounds.project-3 row:1
PRADD 21 "$H1" collaborator-1 true 300;            REVADD 21 CHANGES_REQUESTED "$H1" operator OWNER
PRADD 22 "$H1" app/cromford false 300; REVADD 22 CHANGES_REQUESTED "$H1" operator OWNER
PRADD 23 "$H1" 'cromford[bot]' false 300; REVADD 23 CHANGES_REQUESTED "$H1" operator OWNER
PRADD 24 "$H1" operator false 300;            REVADD 24 CHANGES_REQUESTED "$H1" operator OWNER
PRADD 25 "$H1" collaborator-1 false 300;           REVADD 25 APPROVED "$H1" operator OWNER
PRADD 26 "$H2" collaborator-1 false 300 o/project-3 false false dirty
COMMIT "$H1" 3660 y@example.com; COMMIT "$H2" 3660 y@example.com
RUN
for n in 21 22 23 24 25; do
  grep -q "o-project-3-$n \[external-\|o/project-3#$n.*external-\|external .* o/project-3#$n" "$H/logs/blocked-resolver.log" 2>/dev/null \
    && bad "X11: PR #$n must never be an external candidate: $(LOG | grep "#$n\|-$n" | head -2)" || ok
done
[ "$(grep -c '^rebase|' "$T/hooks.txt")" = 1 ] && grep -qF "|project-3 o-project-3-26 external-dirty https://github.com/o/project-3/pull/26 - -" "$T/hooks.txt" && ok \
  || bad "X11: an outsider's dirty PR must reach br_xpr_rebase once: $(cat "$T/hooks.txt") $(LOG | tail -3)"
[ "$(grep -c . "$T/hooks.txt")" = 1 ] && ok || bad "X11: only #26 may reach a hook: $(cat "$T/hooks.txt")"

# X10: an outsider's branch that LOOKS like a key still gets no key.
RESET; XINSTALL; KNOB external_pr.fix_rounds.project-3 row:1
PRADD 7 "$H1" collaborator-1 false 300 o/project-3 false false clean agent/TK-245 'TK-245: the fix'
REVADD 7 CHANGES_REQUESTED "$H1" operator OWNER; COMMIT "$H1" 3660 y@example.com
RUN
HAS "discovery carried no ticket key" && bad "X10: agent/TK-245 must not derive a key for an external row: $(LOG | grep derived)" || ok
[ -n "$(REC o-project-3-7)" ] && [ -z "$(ls "$H/state/blocked-resolver/project-3/" 2>/dev/null | grep -i TK-245)" ] && ok \
  || bad "X10: the state record must be keyed on the PR rkey, not a ticket: $(ls "$H/state/blocked-resolver/project-3/" 2>/dev/null)"

# ===========================================================================
# F1 / F2: the push right (D3).
# ===========================================================================
RESET; XINSTALL; CANARY_HOOKS; KNOB external_pr.fix_rounds.project-3 row:1
PRADD 7 "$H1" collaborator-1 false 300 collaborator-1/project-3 true false
REVADD 7 CHANGES_REQUESTED "$H1" operator OWNER; COMMIT "$H1" 3660 y@example.com
RUN
HAS "external o/project-3#7: no push right (fork, maintainer edits off) — left for the author" && ok \
  || bad "F1: a fork with maintainer edits off must log no push right: $(LOG | tail -3)"
[ -z "$(REC o-project-3-7)" ] && [ ! -s "$T/hooks.txt" ] && [ "$(NPATCH)" = 0 ] && [ "$(NPUSH)" = 0 ] && ok \
  || bad "F1: no push right writes nothing and calls no hook (rec=$(REC o-project-3-7) hooks=$(cat "$T/hooks.txt"))"
# A fork that DOES allow maintainer edits passes.
RESET; XINSTALL; CANARY_HOOKS; KNOB external_pr.fix_rounds.project-3 row:1
PRADD 7 "$H1" collaborator-1 false 300 collaborator-1/project-3 true true
REVADD 7 CHANGES_REQUESTED "$H1" operator OWNER; COMMIT "$H1" 3660 y@example.com
RUN
[ "$(grep -c '^fix|' "$T/hooks.txt")" = 1 ] && ok || bad "F1+: a fork with maintainer edits on must pass the gate: $(LOG | tail -3)"
# F2: the head repo was deleted.
RESET; XINSTALL; CANARY_HOOKS; KNOB external_pr.fix_rounds.project-3 row:1
PRADD 7 "$H1" collaborator-1 false 300 null
REVADD 7 CHANGES_REQUESTED "$H1" operator OWNER; COMMIT "$H1" 3660 y@example.com
RUN
HAS "external o/project-3#7: push right unreadable" && [ -z "$(REC o-project-3-7)" ] && [ ! -s "$T/hooks.txt" ] && ok \
  || bad "F2: a null head repo is a failed read — rc 3, nothing written: $(LOG | tail -3)"

# Budget: low GitHub budget, no list read at all.
RESET; XINSTALL; KNOB external_pr.fix_rounds.project-3 row:1; TRACER 600
printf '%s\n' '{"resources":{"core":{"remaining":5,"limit":5000,"reset":0},"graphql":{"remaining":5,"limit":5000,"reset":0}}}' > "$T/f/ratelimit.json"
RUN
HAS "the external-PR source is skipped this tick — the GitHub API budget is low" && ok \
  || bad "budget: a low budget must skip the source with one line: $(LOG | tail -3)"
grep -q 'GET repos/o/project-3/pulls ' "$T/gh.txt" && bad "budget: no pulls list may be read on a low budget" || ok

# ===========================================================================
# X9: no external module. A row that arrives anyway is refused with one line.
# The row is hand-fed by a canary module under a name the lane sources.
# ===========================================================================
RESET; KNOB external_pr.fix_rounds.project-3 row:1; TRACER 3660
RUN
grep -q 'external-' "$H/logs/blocked-resolver.log" 2>/dev/null && bad "X9: with no external.sh there must be no external candidate: $(LOG | grep external | head -2)" || ok
grep -q 'external.sh' "$T/run.log" "$H/logs/blocked-resolver.log" 2>/dev/null \
  && bad "X9: an absent module must be silent: $(grep external.sh "$T/run.log" | head -1)" || ok
cat > "$OPTD/extpark.sh" <<EOF
br_opt_external_candidates() { printf 'xreviews\tproject-3\to-project-3-7\texternal-dirty\t%s\t-\t-\t-\n' "$ROW7"; }
EOF
RUN
HAS "project-3/o-project-3-7 [external-dirty]: external PR — the external module is not installed, nothing done" && ok \
  || bad "X9: a hand-fed external row with no module must be refused with one line: $(LOG | tail -3)"
[ "$(NPATCH)" = 0 ] && [ "$(NCOMM)" = 0 ] && [ ! -s "$T/queue.txt" ] && ok \
  || bad "X9: the refused row writes nothing (patch=$(NPATCH) queue=$(cat "$T/queue.txt"))"

# ===========================================================================
# X8: the belt, through the real lane. Every external module is OFF; a canary
# feeds a NON-external reason (build-dead -> rebuild-fresh) for the outsider's
# PR #9. With the record stamped, the guard stops it; with no stamp, the close
# itself refuses on the author.
# ===========================================================================
RESET; KNOB external_pr.fix_rounds.project-3 row:1
PRADD 9 "$H1" collaborator-1 false 300
cat > "$OPTD/mechanical.sh" <<EOF
br_opt_external_candidates() { printf 'xreviews\tproject-3\to-project-3-9\tbuild-dead\thttps://github.com/o/project-3/pull/9\t-\t-\t-\n'; }
EOF
mkdir -p "$H/state/blocked-resolver/project-3"
printf '{"external":"true","attempts":[]}\n' > "$H/state/blocked-resolver/project-3/o-project-3-9.json"
BRENV=(BR_OPT_OFF=external,extfix,extpark,extrebase); RUN; BRENV=()
HAS "project-3/o-project-3-9 [build-dead]: external PR — never closed or rebuilt; left for the author" && ok \
  || bad "X8a/X8c: a stamped record must stop br_rebuild_fresh with every module off: $(LOG | tail -4)"
[ "$(NPATCH)" = 0 ] && [ "$(NCOMM)" = 0 ] && [ ! -s "$T/queue.txt" ] && ! HAS ABANDONED && ok \
  || bad "X8a: no close, no comment, no enqueue, no ABANDONED (patch=$(NPATCH) queue=$(cat "$T/queue.txt"))"
HAS "rungs=0/" && ok || bad "X8a (lane): a parked outsider PR spends no PER_TICK slot: $(LOG | grep 'tick:')"
# No stamp: br_close_pr's own author read refuses.
rm -f "$H/state/blocked-resolver/project-3/o-project-3-9.json" "$H/logs/blocked-resolver.log"
BRENV=(BR_OPT_OFF=external,extfix,extpark,extrebase); RUN; BRENV=()
HAS "refused: https://github.com/o/project-3/pull/9 is an external author's PR — never closed by this lane" && ok \
  || bad "X8b (lane): with no stamp, br_close_pr must refuse on the author: $(LOG | tail -4)"
HAS "project-3/o-project-3-9 [build-dead]: https://github.com/o/project-3/pull/9 is an external author's PR — parked for the author, nothing recorded" && ok \
  || bad "X8b (lane): br_rebuild_fresh must read rc 3 as parked: $(LOG | tail -3)"
HAS "rebuild deferred" && bad "X8b (lane): a refusal is not a 75 deferral: $(LOG | grep deferred)" || ok
HAS "rungs=0/" && ok || bad "X8b (lane): a refused close spends no PER_TICK slot: $(LOG | grep 'tick:')"
[ "$(NPATCH)" = 0 ] && [ "$(NCOMM)" = 0 ] && [ ! -s "$T/queue.txt" ] && ok \
  || bad "X8b (lane): an outsider's PR must not be closed or rebuilt (patch=$(NPATCH) comments=$(NCOMM) queue=$(cat "$T/queue.txt"))"

# ---------------------------------------------------------------------------
# X8, per function, lifted from the lane (sourcing it would run a tick).
# ---------------------------------------------------------------------------
: > "$T/lift.sh"
for fn in br_rkey br_cap_key br_file br_load br_is_external br_fix_terminal br_fix_terminal_word \
          br_abandon br_abandon_rebuild br_xpr_parked br_rebuild_fresh br_slug_of_url br_pr_field br_pr_state br_pr_comment br_close_pr; do
  awk -v f="^$fn\\\\(\\\\)" '
    $0 ~ f { p=1; if ($0 ~ /\}$/ && $0 !~ /\{ *$/) { print; exit } }
    p { print } p && /^}$/ { exit }' "$T/br-corpus.sh" >> "$T/lift.sh"
done
for fn in br_is_external br_fix_terminal br_abandon br_abandon_rebuild br_xpr_parked br_rebuild_fresh br_close_pr; do
  grep -q "^$fn()" "$T/lift.sh" && ok || bad "lift: $fn() was not found in bin/blocked-resolver.sh"
done
LRC=0
LIFT() { # LIFT <spy-mode> <fn> [args...] — runs one lifted function; rc in LRC
  LRC=0
  ( export HARNESS="$H" LOG="$H/logs/blocked-resolver.log" ST="$H/state/blocked-resolver" H OBSERVE=0
    say() { echo "$*" >> "$LOG"; }
    STAMP() { echo t; }
    . "$H/bin/lib/gh-rest.sh"; . "$H/bin/lib/gh-pr-list.sh"
    . "$H/bin/lib/merge-conductor-lib.sh" >/dev/null 2>&1
    . "$T/lift.sh"
    # What lies BEYOND each guard is recorded, so "the guard fired" is the absence
    # of every one of these lines.
    if [ "$1" = spy ]; then
      br_close_pr() { echo "CLOSE $*" >> "$T/x8.txt"; return 0; }
      br_pr_state() { echo "PRSTATE" >> "$T/x8.txt"; echo open; }
      br_abandon() { echo "ABANDON $*" >> "$T/x8.txt"; }
      br_rebuild_fresh() { echo "REBUILD $*" >> "$T/x8.txt"; }
      br_review_cleared() { return 1; }
    fi
    br_record() { echo "RECORD $*" >> "$T/x8.txt"; }
    br_set_outcome() { echo "OUTCOME $*" >> "$T/x8.txt"; }
    br_row_closed() { echo "ROWCLOSED $*" >> "$T/x8.txt"; }
    br_event() { echo "EVENT $*" >> "$T/x8.txt"; }
    br_hold_gate() { return 0; }
    br_rebuild_artifact() { echo plan.md; }
    br_blocked_excerpt() { :; }
    br_ticket_comment() { echo "TICKETCOMMENT $*" >> "$T/x8.txt"; }
    mc_contested_list() { :; }
    shift; "$@" ) || LRC=$?
}
U9=https://github.com/o/project-3/pull/9
# X8a: each terminal, record stamped, nothing beyond the guard runs.
RESET; mkdir -p "$H/state/blocked-resolver/project-3"; PRADD 9 "$H1" collaborator-1 false 300
printf '{"external":"true","attempts":[]}\n' > "$H/state/blocked-resolver/project-3/o-project-3-9.json"
: > "$T/x8.txt"
# Each answers rc 3, never 0: a caller reads rc 0 from br_abandon as "closed
# and ABANDONED recorded" (BH-4667 refute 1).
LIFT spy br_fix_terminal project-3 o-project-3-9 review-changes-requested "$U9" - -
[ "$LRC" = 3 ] && ok || bad "X8a: br_fix_terminal's external guard must answer rc 3 (rc $LRC)"
LIFT nospy br_abandon project-3 o-project-3-9 review-changes-requested "$U9" - "why" -
[ "$LRC" = 3 ] && ok || bad "X8a: br_abandon's external guard must answer rc 3 (rc $LRC)"
LIFT nospy br_rebuild_fresh project-3 o-project-3-9 build-dead "$U9" - -
[ "$LRC" = 3 ] && ok || bad "X8a: br_rebuild_fresh's external guard must answer rc 3 (rc $LRC)"
[ "$(LOG | grep -c 'external PR — never closed or rebuilt; left for the author')" = 3 ] && ok \
  || bad "X8a: each of br_fix_terminal, br_abandon, br_rebuild_fresh must stop at the guard: $(LOG)"
[ ! -s "$T/x8.txt" ] && [ "$(NPATCH)" = 0 ] && [ "$(NCOMM)" = 0 ] && ok \
  || bad "X8a: nothing past the guard may run: $(cat "$T/x8.txt")"
# The guard does NOT fire on an ordinary record (the mutation-proof negative).
rm -f "$H/state/blocked-resolver/project-3/o-project-3-9.json"; : > "$T/x8.txt"; : > "$H/logs/blocked-resolver.log"
LIFT spy br_fix_terminal project-3 o-project-3-9 build-dead "$U9" - -
grep -q '^REBUILD ' "$T/x8.txt" && ok || bad "X8c-: an unstamped, non-external row must reach br_rebuild_fresh: $(cat "$T/x8.txt")"
# X8c: a non-external reason on a stamped record is external.
printf '{"external":"true"}\n' > "$H/state/blocked-resolver/project-3/o-project-3-9.json"
LIFT nospy br_is_external project-3 o-project-3-9 build-dead
[ "$LRC" = 0 ] && ok || bad "X8c: br_is_external must read the stamp (rc $LRC)"
rm -f "$H/state/blocked-resolver/project-3/o-project-3-9.json"
LIFT nospy br_is_external project-3 o-project-3-9 build-dead
[ "$LRC" = 1 ] && ok || bad "X8c: an unstamped non-external row is not external (rc $LRC)"
LIFT nospy br_is_external project-3 o-project-3-9 external-dirty
[ "$LRC" = 0 ] && ok || bad "X8c: an external-* reason is external (rc $LRC)"

# X8b: br_close_pr on the outsider's open PR refuses, writes nothing.
: > "$H/logs/blocked-resolver.log"
LIFT nospy br_close_pr "$U9" why
[ "$LRC" = 3 ] && HAS "refused: $U9 is an external author's PR — never closed by this lane" \
  && [ "$(NPATCH)" = 0 ] && [ "$(NCOMM)" = 0 ] && ok \
  || bad "X8b: br_close_pr on an outsider's PR must be rc 3 with no comment and no PATCH (rc $LRC patch=$(NPATCH) comments=$(NCOMM))"
# ...and br_abandon through it records nothing.
: > "$T/x8.txt"; : > "$H/logs/blocked-resolver.log"
LIFT nospy br_abandon project-3 o-project-3-9 red-twice "$U9" - "why" -
[ "$LRC" = 3 ] && HAS "project-3/o-project-3-9 [red-twice]: $U9 is an external author's PR — parked for the author, nothing recorded" \
  && [ ! -s "$T/x8.txt" ] && ! HAS deferred && ok \
  || bad "X8b: br_abandon over a refused close must park with nothing recorded (rc $LRC): $(LOG) $(cat "$T/x8.txt")"
# ...and br_abandon_rebuild over that refused close tells the ticket NOTHING:
# its comment is written once, ever, and must never say a PR it did not close
# is closed (BH-4667 refute 1).
: > "$T/x8.txt"; : > "$H/logs/blocked-resolver.log"
mkdir -p "$T/rec9"; echo "PLAN_BLOCKED plan.md" > "$T/rec9/RESULT"
LIFT nospy br_abandon_rebuild project-3 o-project-3-9 build-dead "$U9" "$T/rec9" TK-9
! grep -q TICKETCOMMENT "$T/x8.txt" && [ ! -s "$T/x8.txt" ] && [ "$(NPATCH)" = 0 ] && [ "$(NCOMM)" = 0 ] && ok \
  || bad "X8b: br_abandon_rebuild over a refused close must post no ticket comment and record nothing: $(cat "$T/x8.txt")"
# X8d: our own spellings, an empty/null login, and a failed author read keep today's path.
for who in app/cromford 'cromford[bot]' operator '' null; do
  RESET; PRADD 9 "$H1" "$who" false 300
  LIFT nospy br_close_pr "$U9" why
  [ "$LRC" = 0 ] && [ "$(NPATCH)" = 1 ] && ok \
    || bad "X8d: login '$who' is not an outsider — br_close_pr must close as today (rc $LRC patch=$(NPATCH)): $(LOG | tail -2)"
done
RESET; PRADD 9 "$H1" collaborator-1 false 300; touch "$T/f/prfail-9"
LIFT nospy br_close_pr "$U9" why
[ "$LRC" = 75 ] && [ "$(NPATCH)" = 0 ] && ok \
  || bad "X8d: a failed read is 75 (unverifiable), never a refusal and never a close (rc $LRC patch=$(NPATCH))"
# The state read answers open, then the AUTHOR read fails: still 75, never a close.
RESET; PRADD 9 "$H1" collaborator-1 false 300; touch "$T/f/prfail2-9"
LIFT nospy br_close_pr "$U9" why
[ "$LRC" = 75 ] && [ "$(NPATCH)" = 0 ] && [ "$(NCOMM)" = 0 ] && ok \
  || bad "X8d: a failed author read after a good state read is 75, never a close (rc $LRC patch=$(NPATCH) comments=$(NCOMM))"
# X8e: the terminal word.
OUTW=$( export H; . "$T/lift.sh"; br_fix_terminal_word external-changes-requested )
OUTR=$( export H; . "$T/lift.sh"; br_fix_terminal_word review-changes-requested )
OUTA=$( export H; . "$T/lift.sh"; BR_XPR_ACTIVE=1 br_fix_terminal_word build-dead )
[ "$OUTW" = 'PARKED for the author instead' ] && [ "$OUTA" = 'PARKED for the author instead' ] && ok \
  || bad "X8e: an external row's terminal word is PARKED for the author instead (got '$OUTW' / '$OUTA')"
[ "$OUTR" = 'ABANDONED instead' ] && ok || bad "X8e: the review terminal word is unchanged (got '$OUTR')"

echo "external-pr-source.bh-4667: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
