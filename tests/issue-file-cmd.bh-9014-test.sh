#!/bin/bash
# tests/issue-file-cmd.bh-9014-test.sh — BH-9014: the hub side of the console's
# file_issue command (the MCP `file_issue` tool).
#
# bin/lib/tracker/issue-file-cmd.sh files ONE GitHub issue as the App through
# gh_issue_create (REST), exactly once per console command id: the issue body
# ends with `<!-- mc-command:<id> -->`, and a re-run that finds the marker in
# the repo's newest issues files nothing. bin/poll-commands.sh runs it from one
# marked arm.
#
# `gh` is a stub on PATH. It keeps the repo's issues (newest first) as state,
# so a create is seen by the next list read; any other argv shape exits 99.
# gh_auth_for and gh_auth_reset are stubs defined after the lib. The lookback
# is the poll-commands lane knob FILE_ISSUE_LOOKBACK, an env var.
#
# Sections: I1-I8 files and the per-id marker, I9 refusals, I10-I13 failures,
# I14 no leak, A1-A3 the poller arm, K1 the lane knob.
# Run from anywhere: tests/issue-file-cmd.bh-9014-test.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PC="$DIR/bin/poll-commands.sh"
LIB_REL=bin/lib/tracker/issue-file-cmd.sh
KNOB_REL=catalog/lanes.d/poll-commands.knobs.d/FILE_ISSUE_LOOKBACK.json
[ -r "$DIR/$LIB_REL" ] || { echo "FAIL: bin/lib/tracker/issue-file-cmd.sh is missing"; echo "issue-file-cmd: 0 passed, 1 failed"; exit 1; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

mkdir -p "$T/h" "$T/stubbin" "$T/state" "$T/tmp"
scratch_install_closure bin/fleet-conf.sh "$T/h" >/dev/null || { echo "FAIL: cannot install fleet-conf.sh"; exit 1; }
scratch_install_closure "$LIB_REL" "$T/h" >/dev/null || { echo "FAIL: cannot install issue-file-cmd.sh"; exit 1; }
LIB="$T/h/bin/lib/tracker/issue-file-cmd.sh"
cat > "$T/h/fleet.conf" <<'EOF'
# fixture
fixture-proj example-org/fixture -                     -              1 hub
inapp-proj   example-org/inapp   https://inapp.example /api/board     6 box-x
EOF
export FLEET_CONF="$T/h/fleet.conf"

# gh stub. One log line per call: the GH_TOKEN it ran with and its argv.
# State: $GHSTATE/issues.json, newest first; a create prepends to it and copies
# the body file to $GHSTATE/lastbody. GH_LIST_RC/_ERR/_RAW and
# GH_CREATE_RC/_MSG/_ERR/_EMPTY change one kind of call.
cat > "$T/stubbin/gh" <<'EOF'
#!/bin/bash
method=GET; path=""; title=""; bodyf=""; a=("$@")
for ((i=0; i<${#a[@]}; i++)); do
  case "${a[$i]}" in
    -X) method="${a[$((i+1))]}" ;;
    -f) case "${a[$((i+1))]}" in title=*) title="${a[$((i+1))]#title=}" ;; esac ;;
    -F) case "${a[$((i+1))]}" in body=@*) bodyf="${a[$((i+1))]#body=@}" ;; esac ;;
    repos/*) path="${a[$i]}" ;;
  esac
done
printf 'TOKEN=%s %s\n' "${GH_TOKEN:-}" "$*" >> "$GHLOG"
fail() { [ -n "$2" ] && echo "$2" >&2; exit "$1"; }
[ "${1:-}" = api ] || fail 99 "unexpected gh call: $*"
case "$method $path" in
  "GET repos/example-org/fixture/issues?"*)
    [ "${GH_LIST_RC:-0}" = 0 ] || fail "$GH_LIST_RC" "${GH_LIST_ERR:-}"
    if [ -n "${GH_LIST_RAW:-}" ]; then printf '%s\n' "$GH_LIST_RAW"; else cat "$GHSTATE/issues.json"; fi ;;
  "POST repos/example-org/fixture/issues")
    if [ "${GH_CREATE_RC:-0}" != 0 ]; then
      [ -n "${GH_CREATE_MSG:-}" ] && jq -nc --arg m "$GH_CREATE_MSG" '{message:$m}'
      fail "$GH_CREATE_RC" "${GH_CREATE_ERR:-}"
    fi
    [ -n "${GH_CREATE_EMPTY:-}" ] && { echo '{}'; exit 0; }
    cp "$bodyf" "$GHSTATE/lastbody"
    n=$(( $(jq length "$GHSTATE/issues.json") + 500 ))
    jq -c --rawfile b "$bodyf" --arg t "$title" --argjson n "$n" \
      '[{number:$n, html_url:("https://github.com/example-org/fixture/issues/" + ($n|tostring)), title:$t, body:$b}] + .' \
      "$GHSTATE/issues.json" > "$GHSTATE/i.tmp" && mv "$GHSTATE/i.tmp" "$GHSTATE/issues.json"
    jq -c '.[0]' "$GHSTATE/issues.json" ;;
  *) fail 99 "unexpected gh call: $method $path" ;;
esac
EOF
chmod +x "$T/stubbin/gh"

# Stubs defined AFTER the lib, so they replace gh-app-auth.sh's real ones.
cat > "$T/stubs.sh" <<'EOF'
gh_auth_for() { printf 'gh_auth_for %s\n' "$1" >> "$GHLOG"; export GH_TOKEN="${STUB_TOKEN:-ghs_fixture_app_9014}"; return 0; }
gh_auth_reset() { printf 'gh_auth_reset\n' >> "$GHLOG"; export GH_TOKEN=ghp_fixture_pat; }
[ -n "${STUB_NO_CREATE:-}" ] && unset -f gh_issue_create
EOF

GHLOG="$T/gh.log"; GHSTATE="$T/state"
ALL_OUT=""
reset_state() { echo "${1:-[]}" > "$GHSTATE/issues.json"; rm -f "$GHSTATE/lastbody"; }
# ifc <project> <payload> <id>: stdout in OUT, rc in RC. The log is cleared per
# call; the issue state is not, so I2 sees what I1 filed.
ifc() {
  : > "$GHLOG"
  OUT=$(unset FILE_ISSUE_LOOKBACK; [ -n "${LB+x}" ] && export FILE_ISSUE_LOOKBACK="$LB"
    PATH="$T/stubbin:$PATH" HARNESS="$T/h" GHLOG="$GHLOG" GHSTATE="$GHSTATE" GH_TOKEN=ghp_fixture_pat TMPDIR="$T/tmp" \
    bash -c 'set -uo pipefail; . "$0"; . "$1"; ifcmd_run "$2" "$3" "$4"' "$LIB" "$T/stubs.sh" "$@" 2>"$T/stderr"); RC=$?
  ALL_OUT+="$OUT"$'\n'"$(cat "$T/stderr")"$'\n'
}
creates() { grep -c -- '-X POST repos/example-org/fixture/issues' "$GHLOG" 2>/dev/null || true; }
gh_calls() { grep -c '^TOKEN=' "$GHLOG" 2>/dev/null || true; }
listq() { grep -v -- '-X POST' "$GHLOG" | grep -o 'repos/example-org/fixture/issues?[^ ]*' | head -1; }
# The text minus every token that holds a '/': a mktemp name is random and can
# hold the body text by chance.
nopaths() { sed -E 's#[^[:space:]]*/[^[:space:]]*##g' <<<"$1"; }
nissues() { jq length "$GHSTATE/issues.json"; }
# The payload F1 of console-ui/tests/board-commands.bh-9014.test.js stores, byte for byte.
P1='{"title":"t1","body":"b1","actor":"console"}'

echo "--- I1: the first run files one issue, as the App, ending with the marker"
reset_state
ifc fixture-proj "$P1" 42
CL=$(grep -- '-X POST' "$GHLOG")
[ "$RC" = 0 ] && [ "$OUT" = "filed #500 https://github.com/example-org/fixture/issues/500 as the App (command 42, actor console)" ] \
  && [ "$(creates)" = 1 ] && [ "$(nissues)" = 1 ] \
  && grep -q '^TOKEN=ghs_fixture_app_9014 ' <<<"$CL" \
  && grep -q -- '-f title=t1 ' <<<"$CL" && grep -q -- '-F body=@' <<<"$CL" && ! grep -q 'labels' <<<"$CL" \
  && ! grep -qw 'b1' <<<"$(nopaths "$CL")" \
  && [ "$(cat "$GHSTATE/lastbody")" = "$(printf 'b1\n\n<!-- mc-command:42 -->')" ] \
  && grep -q '^gh_auth_reset$' "$GHLOG" \
  && ok || bad "I1 (rc=$RC out=$OUT log=$(cat "$GHLOG"))"

echo "--- I2: the same command id again files nothing"
ifc fixture-proj "$P1" 42
[ "$RC" = 0 ] && [ "$OUT" = "issue already filed: https://github.com/example-org/fixture/issues/500 (command 42)" ] \
  && [ "$(creates)" = 0 ] && [ "$(nissues)" = 1 ] && ok || bad "I2 (rc=$RC out=$OUT n=$(nissues))"

echo "--- I3: a person moved the marker mid-body: still filed"
reset_state '[{"number":9,"html_url":"https://github.com/example-org/fixture/issues/9","body":"top\n<!-- mc-command:42 -->\nedited below"}]'
ifc fixture-proj "$P1" 42
[ "$RC" = 0 ] && [ "$OUT" = "issue already filed: https://github.com/example-org/fixture/issues/9 (command 42)" ] && [ "$(creates)" = 0 ] \
  && ok || bad "I3 (rc=$RC out=$OUT)"

echo "--- I4-I7: near misses file a new issue"
while IFS='|' read -r label state; do
  reset_state "$state"
  ifc fixture-proj "$P1" 42
  [ "$RC" = 0 ] && [[ "$OUT" == "filed #"* ]] && [ "$(creates)" = 1 ] && ok || bad "$label (rc=$RC out=$OUT)"
done <<'EOF'
I4 the marker of id 421|[{"number":9,"html_url":"u9","body":"x\n\n<!-- mc-command:421 -->"}]
I5 no comment delimiters|[{"number":9,"html_url":"u9","body":"x mc-command:42 y"}]
I6 a pull request|[{"number":9,"html_url":"u9","body":"x\n\n<!-- mc-command:42 -->","pull_request":{"url":"p"}}]
I7 a null body|[{"number":8,"html_url":"u8","body":null},{"number":9,"html_url":"u9","body":"<!-- mc-command:7 -->"}]
EOF

echo "--- I8: the dedup read is one page of the newest issues"
reset_state
ifc fixture-proj "$P1" 42
[ "$(listq)" = "repos/example-org/fixture/issues?state=all&sort=created&direction=desc&per_page=100" ] \
  && ! grep -q -- '--paginate' "$GHLOG" && ok || bad "I8 (q=$(listq))"

echo "--- I9: refusals make no gh call"
while IFS='|' read -r proj payload id want; do
  reset_state
  ifc "$proj" "$payload" "$id"
  [ "$RC" = 3 ] && [ "$OUT" = "$want" ] && [ "$(gh_calls)" = 0 ] && ok || bad "I9 $proj $payload $id (rc=$RC out=$OUT want=$want)"
done <<'EOF'
inapp-proj|{"title":"t"}|45|refused: inapp-proj is not a GitHub-issues board
unknown-proj|{"title":"t"}|45|refused: unknown-proj is not a GitHub-issues board
fixture-proj;rm|{"title":"t"}|45|refused: fixture-proj;rm is not a GitHub-issues board
fixture-proj|{"body":"b"}|45|refused: empty title
fixture-proj|{"title":"   "}|45|refused: empty title
fixture-proj|{"title":7}|45|refused: empty title
fixture-proj|{"title":"t","body":9}|45|refused: bad body
fixture-proj|{"title":"t"}|abc|refused: bad command id
fixture-proj|{"title":"t"}|0|refused: bad command id
fixture-proj|["t"]|45|refused: bad payload
fixture-proj|not json|45|refused: bad payload
EOF
# No body is an empty body: the issue body is the marker alone.
reset_state
ifc fixture-proj '{"title":"t","actor":"console"}' 46
[ "$RC" = 0 ] && [ "$(cat "$GHSTATE/lastbody")" = "<!-- mc-command:46 -->" ] && ok || bad "I9 no body (rc=$RC out=$OUT)"
# An unreadable fleet.conf is retryable, never refused:.
mv "$T/h/bin/fleet-conf.sh" "$T/h/bin/fleet-conf.real"
printf '#!/bin/bash\nexit 1\n' > "$T/h/bin/fleet-conf.sh"; chmod +x "$T/h/bin/fleet-conf.sh"
ifc fixture-proj "$P1" 47
[ "$RC" = 1 ] && [[ "$OUT" != refused:* ]] && [ "$(gh_calls)" = 0 ] && ok || bad "I9 fleet-conf read fails (rc=$RC out=$OUT)"
mv "$T/h/bin/fleet-conf.real" "$T/h/bin/fleet-conf.sh"

echo "--- I10: Validation Failed is a refusal; a rate limit is retryable"
reset_state
GH_CREATE_RC=1 GH_CREATE_MSG='Validation Failed' GH_CREATE_ERR='gh: Validation Failed (HTTP 422)' ifc fixture-proj "$P1" 48
[ "$RC" = 3 ] && [ "$OUT" = "refused: GitHub refused the issue (Validation Failed)" ] && ok || bad "I10 422 (rc=$RC out=$OUT)"
GH_CREATE_RC=1 GH_CREATE_MSG='API rate limit exceeded for installation' GH_CREATE_ERR='gh: HTTP 403' ifc fixture-proj "$P1" 48
[ "$RC" = 1 ] && [ "$OUT" = "issue not filed on example-org/fixture (API rate limit exceeded for installation)" ] && ok || bad "I10 rate limit (rc=$RC out=$OUT)"
GH_CREATE_RC=1 GH_CREATE_ERR='gh: Not Found (HTTP 404)' ifc fixture-proj "$P1" 48
[ "$RC" = 1 ] && [[ "$OUT" != refused:* ]] && ok || bad "I10 404 (rc=$RC out=$OUT)"
GH_CREATE_RC=1 GH_CREATE_MSG='Validation Failed for title' ifc fixture-proj "$P1" 48
[ "$RC" = 1 ] && ok || bad "I10 not the exact line (rc=$RC out=$OUT)"

echo "--- I11: a failed or non-array list read files nothing"
reset_state
GH_LIST_RC=1 GH_LIST_ERR='gh: Bad Gateway (HTTP 502)' ifc fixture-proj "$P1" 49
[ "$RC" = 1 ] && [ "$(creates)" = 0 ] && [ "$OUT" = "issue not filed: issue list read failed on example-org/fixture (gh: Bad Gateway (HTTP 502)); retry" ] \
  && ok || bad "I11 502 (rc=$RC out=$OUT)"
GH_LIST_RAW='{"message":"Not Found"}' ifc fixture-proj "$P1" 49
[ "$RC" = 1 ] && [ "$(creates)" = 0 ] && [[ "$OUT" != refused:* ]] && ok || bad "I11 non-array (rc=$RC out=$OUT)"
GH_LIST_RAW='not json' ifc fixture-proj "$P1" 49
[ "$RC" = 1 ] && [ "$(creates)" = 0 ] && ok || bad "I11 not json (rc=$RC out=$OUT)"

echo "--- I12: the lookback is the lane knob FILE_ISSUE_LOOKBACK, 1..100, else 100"
for v in 5 1 100; do
  reset_state
  LB="$v" ifc fixture-proj "$P1" 50
  [[ "$(listq)" == *"&per_page=$v" ]] && [ "$RC" = 0 ] && ok || bad "I12 $v (q=$(listq))"
done
for v in 0 101 abc -3 7x ""; do
  reset_state
  LB="$v" ifc fixture-proj "$P1" 50
  [[ "$(listq)" == *"&per_page=100" ]] && [ "$RC" = 0 ] && ok || bad "I12 '$v' (q=$(listq))"
done
reset_state
unset LB
ifc fixture-proj "$P1" 50
[[ "$(listq)" == *"&per_page=100" ]] && [ "$RC" = 0 ] && ok || bad "I12 unset (q=$(listq))"

echo "--- I13: no App token, an empty create answer, no create helper"
reset_state
STUB_TOKEN=ghp_fixture_x ifc fixture-proj "$P1" 51
[ "$RC" = 1 ] && [ "$OUT" = "issue not filed: no App token on this box; retry" ] && [ "$(gh_calls)" = 0 ] && ok || bad "I13 no App token (rc=$RC out=$OUT)"
GH_CREATE_EMPTY=1 ifc fixture-proj "$P1" 51
[ "$RC" = 1 ] && [ "$OUT" = "issue not filed on example-org/fixture (gh_issue_create: no issue number in the response)" ] \
  && ok || bad "I13 create {} (rc=$RC out=$OUT)"
STUB_NO_CREATE=1 ifc fixture-proj "$P1" 51
[ "$RC" = 1 ] && [ "$OUT" = "issue not filed: tracker/gh-issue-create.sh not loaded" ] && [ "$(gh_calls)" = 0 ] \
  && ok || bad "I13 no helper (rc=$RC out=$OUT)"
# Never the GraphQL create, in the lib or in any call it made.
! grep -q 'issue create' <<<"$(grep -v '^[[:space:]]*#' "$LIB")" && ok || bad "I13b the lib calls gh issue create"
! grep -q 'issue create' "$GHLOG" && ok || bad "I13b a gh issue create call"

echo "--- I14: no token or body text in any output; no temp file left"
! grep -q 'ghs_fixture_app_9014' <<<"$ALL_OUT" && ! grep -qw 'b1' <<<"$(nopaths "$ALL_OUT")" && ok || bad "I14 leak in output"
[ -z "$(ls -A "$T/tmp")" ] && ok || bad "I14 temp files left: $(ls -A "$T/tmp")"

echo "--- A1-A3: the poll-commands arm, extracted by its markers"
{ echo 'case "$TYPE" in'
  awk '/^    # >>> file_issue handler/{f=1;next} /^    # <<< file_issue handler/{exit} f{print}' "$PC"
  echo '  *) RESULT="unknown command type $TYPE" ;;'
  echo 'esac'
} > "$T/arm.body"
if [ "$(wc -l < "$T/arm.body")" -le 4 ]; then
  bad "could not extract the file_issue handler: markers missing?"
else
  ! grep -qE 'box_ccmd_forward|bcx_run' "$T/arm.body" && ok || bad "A the arm is not forwarded"
  arm() { # arm <type> <stub-rc|none> -> "OK=.. OUTCOME=.. RESULT=.."
    TYPE="$1" SRC="$2" bash -c '
      set -uo pipefail
      if [ "$SRC" != none ]; then ifcmd_run() { echo "$1 $2 $3" > "$0.args"; [ "$SRC" = 3 ] && echo "refused: empty title" || echo "r$SRC"; return "$SRC"; }; fi
      ID=42 PROJECT=fixture-proj PAYLOAD="{\"title\":\"t1\"}" OK=false RESULT="" OUTCOME=""
      . "$0"; echo "OK=$OK OUTCOME=$OUTCOME RESULT=$RESULT"' "$T/arm.body"
  }
  [ "$(arm file_issue 0)" = "OK=true OUTCOME= RESULT=r0" ] && [ "$(cat "$T/arm.body.args")" = 'fixture-proj {"title":"t1"} 42' ] \
    && ok || bad "A1 rc 0 (got $(arm file_issue 0))"
  [ "$(arm file_issue 3)" = "OK=false OUTCOME=refused RESULT=refused: empty title" ] && ok || bad "A2 rc 3 (got $(arm file_issue 3))"
  [ "$(arm file_issue 1)" = "OK=false OUTCOME= RESULT=r1" ] && ok || bad "A2 rc 1 (got $(arm file_issue 1))"
  [ "$(arm file_issue none)" = "OK=false OUTCOME= RESULT=issue not filed (lib not loaded)" ] && ok || bad "A3 lib absent (got $(arm file_issue none))"
  # End to end: the real lib behind the real arm, twice with one command id.
  reset_state; : > "$GHLOG"
  e2e() {
    PATH="$T/stubbin:$PATH" HARNESS="$T/h" GHLOG="$GHLOG" GHSTATE="$GHSTATE" GH_TOKEN=ghp_fixture_pat TMPDIR="$T/tmp" \
      TYPE=file_issue ID=77 PROJECT=fixture-proj PAYLOAD='{"title":"from the MCP","body":"x","actor":"operator"}' bash -c '
        set -uo pipefail; . "$0"; . "$1"; OK=false RESULT="" OUTCOME=""
        . "$2"; echo "OK=$OK OUTCOME=$OUTCOME RESULT=$RESULT TOKEN=$GH_TOKEN"' "$LIB" "$T/stubs.sh" "$T/arm.body"
  }
  E1=$(e2e); E2=$(e2e)
  [ "$E1" = "OK=true OUTCOME= RESULT=filed #500 https://github.com/example-org/fixture/issues/500 as the App (command 77, actor operator) TOKEN=ghp_fixture_pat" ] \
    && [ "$E2" = "OK=true OUTCOME= RESULT=issue already filed: https://github.com/example-org/fixture/issues/500 (command 77) TOKEN=ghp_fixture_pat" ] \
    && [ "$(nissues)" = 1 ] && ok || bad "A e2e arm + lib (e1=$E1 e2=$E2 n=$(nissues))"
fi
grep -qxF '[ -r "$HARNESS/bin/lib/tracker/issue-file-cmd.sh" ] && . "$HARNESS/bin/lib/tracker/issue-file-cmd.sh"' "$PC" \
  && ok || bad "A3 guarded source line in poll-commands"

echo "--- K1: the lane registry lists FILE_ISSUE_LOOKBACK on poll-commands"
[ -r "$DIR/$KNOB_REL" ] || bad "K1 $KNOB_REL is missing"
KJ=$(HARNESS_TEST_SANDBOX=1 "$DIR/bin/lanes-build.sh" --root "$DIR" 2>"$T/k1.err"); KRC=$?
K=$(jq -c '.lanes[] | select(.id=="poll-commands") | .knobs[] | select(.env=="FILE_ISSUE_LOOKBACK") | [.type,.default,.min,.max]' <<<"$KJ" 2>/dev/null)
[ "$KRC" = 0 ] && [ "$K" = '["int",100,1,100]' ] && ok || bad "K1 (rc=$KRC knob=$K err=$(head -3 "$T/k1.err"))"

echo "issue-file-cmd: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
