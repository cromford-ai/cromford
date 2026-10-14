#!/bin/bash
# tests/token-redact.bh-6672-test.sh — bin/lib/token-redact.sh turns a
# GitHub-token-shaped string into `<redacted:github-token>`, and the build
# writes its suite output and its PR bodies through it.
#
# WHY (BH-6672). A suite printed the pool box's real App installation token,
# and HARNESS_IMPACT_GATE_RUN copied the suite output into $BUILD/harness-suite
# unscrubbed, where a review lens read it. R1-R12 pin the scrub itself, W1-W4
# pin the wiring in bin/lib/rb/gates.sh, pr.sh and result.sh.
#
# Every fake token is built at run time and carries the word "fixture". No
# token-shaped literal is written in this file. No network, nothing outside $T.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

rep() { printf "$1%.0s" $(seq 1 "$2"); }   # rep <char> <n>
MARK='<redacted:github-token>'
S36="fixture$(rep Q 29)"                     # 36 alnum, no underscore
F_GHS="ghs_$S36"
F_GHP="ghp_$S36"
F_GHO30="gho_fixture$(rep Q 23)"             # exactly 30 alnum
GP="github""_pat_"                           # split: no PAT prefix literal in source
F_PAT="${GP}fixture_$(rep Q 64)"             # 82 of [A-Za-z0-9_]
F_GHS29="ghs_fixture$(rep Q 22)"             # 29 alnum: one under the floor
# The newer installation-token shape: an id, an underscore, a JWT (BH-6672: the
# pool box token was this shape, and a classic-only pattern let it through).
F_JWT="ghs_1234567_eyJfixture$(rep Q 20).eyJfixture-$(rep R 20)_x.sigfixture$(rep S 20)"

# ── R1. the lib exists and loads ────────────────────────────────────────────
LIB="$DIR/bin/lib/token-redact.sh"
# shellcheck source=bin/lib/token-redact.sh
if [ -r "$LIB" ] && . "$LIB" && command -v token_redact >/dev/null && command -v token_redact_file >/dev/null; then ok
else bad "R1: bin/lib/token-redact.sh must exist and define token_redact and token_redact_file"
  echo "token-redact.bh-6672-test: $PASS pass, $FAIL fail"; exit 1
fi

red() { printf '%s\n' "$1" | token_redact; }
same() { # same <case> <input> <expected>
  local got; got=$(red "$2")
  [ "$got" = "$3" ] && ok || bad "$1: expected [$3], got [$got]"
}

# ── R1-R6. redact ───────────────────────────────────────────────────────────
same R1 "token=$F_GHS end" "token=$MARK end"
same R2 "a $F_GHP b" "a $MARK b"
same R3 "edge $F_GHO30." "edge $MARK."
same R4 "pat: $F_PAT;" "pat: $MARK;"
same R5 "https://x-access-token:tok-fixture-1@github.com/o/r.git" "https://x-access-token:$MARK@github.com/o/r.git"
same R6 "$F_GHS and $F_GHP" "$MARK and $MARK"
same R6b "token is $F_JWT)" "token is $MARK)"

# ── R7-R11. keep ────────────────────────────────────────────────────────────
for k in ghs_fixture_installation_token "$F_GHS29" gh_app_only_for "ghs_" "${GP}short" ghs_1234567_short; do
  same "R7-R11 keep" "x $k y" "x $k y"
done

# ── R12. token_redact_file ──────────────────────────────────────────────────
printf 'HARNESS_SUITE: x\nFAIL: leaked %s here\nHARNESS_EXIT: 1\n' "$F_GHS" > "$T/sample.log"
token_redact_file "$T/sample.log"; RC=$?
[ "$RC" = 0 ] && ok || bad "R12: an in-place scrub must return 0 (got $RC)"
grep -qF "$F_GHS" "$T/sample.log" && bad "R12: the fake token must be gone from the sample log" || ok
[ "$(sed -n 2p "$T/sample.log")" = "FAIL: leaked $MARK here" ] && ok || bad "R12: the line must carry the marker (got $(sed -n 2p "$T/sample.log"))"
[ "$(wc -l < "$T/sample.log")" = 3 ] && ok || bad "R12: the scrub must keep every line"
ls "$T"/sample.log.redact.* >/dev/null 2>&1 && bad "R12: the tmp file must not be left behind" || ok
token_redact_file "$T/no-such.log"; RC=$?
[ "$RC" = 0 ] && [ ! -e "$T/no-such.log" ] && ok || bad "R12: a missing path is rc 0 and creates nothing (rc $RC)"
mkdir -p "$T/adir"
token_redact_file "$T/adir"; RC=$?
[ "$RC" = 1 ] && [ -z "$(ls -A "$T/adir")" ] && ok || bad "R12: a directory is rc 1 and nothing written (rc $RC)"
# Fail closed: a scrub whose sed fails replaces the file with one line, never
# keeps it as written. A stub sed on PATH is the failure (root ignores modes).
mkdir -p "$T/badsed"; printf '#!/bin/bash\nexit 4\n' > "$T/badsed/sed"; chmod +x "$T/badsed/sed"
printf 'leak %s\n' "$F_GHS" > "$T/f.log"
PATH="$T/badsed:$PATH" token_redact_file "$T/f.log"; RC=$?
[ "$RC" = 1 ] && ok || bad "R12: a scrub that cannot run must return 1 (got $RC)"
grep -qF "$F_GHS" "$T/f.log" && bad "R12: an unscrubbable file must never keep its token" || ok
[ "$(cat "$T/f.log")" = 'HARNESS_REDACT: failed — output withheld (token scrub could not run)' ] \
  && ok || bad "R12: an unscrubbable file must say why it is empty (got $(cat "$T/f.log"))"
ls "$T"/f.log.redact.* >/dev/null 2>&1 && bad "R12: a failed scrub must remove its tmp" || ok

# ── W. the wiring in run-build ──────────────────────────────────────────────
. "$DIR/tests/lib/rb-all.sh" || exit 1
RB=$(rb_all "$DIR" "$T/run-build.all.sh")
awk '/^# >>> harness suite run/{f=1;next} /^# <<< harness suite run/{exit} f' "$RB" > "$T/suite-run.sh"
grep -q '^RB_TOKEN_REDACT()' "$T/suite-run.sh" && ok || bad "W: RB_TOKEN_REDACT must be defined inside the harness suite run block"
mkdir -p "$T/h/bin/lib"
scratch_install_closure bin/lib/token-redact.sh "$T/h" >/dev/null || bad "W: cannot install the lib into the scratch harness"

suite() { # suite <npm|gate> <harness-dir> -> HARNESS_SUITE_RUN harness-suite lenses
  local REPO="$T/repo-$1"
  scratch_rm "$REPO"; scratch_rm "$T/build"; mkdir -p "$REPO/bin" "$T/build" "$T/fakebin"
  if [ "$1" = npm ]; then
    printf '{"scripts":{"test":"x"}}\n' > "$REPO/package.json"
    printf '#!/bin/bash\nprintf "npm stub leaked %%s\\n" "%s"\n' "$F_GHS" > "$T/fakebin/npm"
    chmod +x "$T/fakebin/npm"
  else
    printf '#!/bin/bash\nprintf "gate stub leaked %%s\\n" "%s"\nexit 0\n' "$F_GHS" > "$REPO/bin/test-impact-gate.sh"
    chmod +x "$REPO/bin/test-impact-gate.sh"
  fi
  ( cd "$REPO" || exit 1
    export PATH="$T/fakebin:$PATH" HARNESS="$2" BUILD="$T/build" PROJECT=p KEY=K-1 TEST_SELECT=0 BASE=main
    STAMP() { echo stamp; }
    # This shell sourced the lib for R1-R12; run-build has not, so drop it.
    unset -f token_redact token_redact_file
    # shellcheck source=/dev/null
    . "$T/suite-run.sh"
    HARNESS_SUITE_RUN harness-suite lenses )
}
check_suite() { # check_suite <case>
  local f="$T/build/harness-suite"
  grep -qF "$F_GHS" "$f" && bad "$1: the fake token must not reach \$BUILD/harness-suite" || ok
  grep -qF "leaked $MARK" "$f" && ok || bad "$1: the scrubbed line must carry the marker ($(cat "$f"))"
  head -1 "$f" | grep -q '^HARNESS_SUITE:' && ok || bad "$1: line 1 must stay HARNESS_SUITE: ($(head -1 "$f"))"
  [ "$(tail -1 "$f")" = "HARNESS_EXIT: 0" ] && ok || bad "$1: the last line must stay HARNESS_EXIT: 0 ($(tail -1 "$f"))"
}
# W1 — the impact-gate arm (this repo's shape).
suite gate "$T/h"; check_suite W1
# W2 — the npm arm.
suite npm "$T/h"; check_suite W2

# W3 — the PR body is scrubbed before it is created or edited.
awk '/_pr_self_check_prepush "\$BUILD\/pr-body.md" open$/{a=NR} /^RB_TOKEN_REDACT "\$BUILD\/pr-body.md"$/{r=NR} /gh_pr_create_ladder "\$PCF_SLUG"/ && !c{c=NR}
     END{exit !(a && r && c && a < r && r < c)}' "$DIR/bin/lib/rb/pr.sh" \
  && ok || bad "W3: pr.sh must run RB_TOKEN_REDACT on pr-body.md after the self-check and before the create ladder"
awk '/_pr_self_check_prepush "\$BUILD\/pr-body-edit.md" edit$/{a=NR} /RB_TOKEN_REDACT "\$BUILD\/pr-body-edit.md"$/{r=NR} /gh pr edit "\$PR_URL" --body/ && !c{c=NR}
     END{exit !(a && r && c && a < r && r < c)}' "$DIR/bin/lib/rb/result.sh" \
  && ok || bad "W3: result.sh must run RB_TOKEN_REDACT on pr-body-edit.md after the self-check and before gh pr edit"
printf '## Verify\n\nclone https://x-access-token:%s@github.com/o/r.git\n' "$F_GHS" > "$T/pr-body.md"
( export HARNESS="$T/h" BUILD="$T/build" PROJECT=p KEY=K-1
  STAMP() { echo stamp; }
  unset -f token_redact token_redact_file
  . "$T/suite-run.sh"
  RB_TOKEN_REDACT "$T/pr-body.md" ); RC=$?
[ "$RC" = 0 ] && ok || bad "W3: RB_TOKEN_REDACT must return 0 (got $RC)"
grep -qF "$F_GHS" "$T/pr-body.md" && bad "W3: the PR body must lose the fake token" || ok
grep -qxF "clone https://x-access-token:$MARK@github.com/o/r.git" "$T/pr-body.md" && ok || bad "W3: the PR body must carry the marker ($(cat "$T/pr-body.md"))"

# W4 — no lib on the harness: the build goes on, the file is untouched, one log line.
mkdir -p "$T/h-nolib/bin/lib"
suite gate "$T/h-nolib"; RC=$?
[ "$RC" = 0 ] && ok || bad "W4: a missing lib must never stop the suite run (rc $RC)"
grep -qF "$F_GHS" "$T/build/harness-suite" && ok || bad "W4: with no lib the file is left as written"
[ "$(grep -c 'token-redact: bin/lib/token-redact.sh missing' "$T/build/pipeline.log")" = 1 ] \
  && ok || bad "W4: pipeline.log must carry one 'token-redact: ... missing' line ($(cat "$T/build/pipeline.log"))"

echo "token-redact.bh-6672-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
