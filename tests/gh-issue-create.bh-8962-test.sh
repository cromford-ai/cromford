#!/bin/bash
# tests/gh-issue-create.bh-8962-test.sh — BH-8962: every issue the harness files
# goes through ONE REST helper, bin/lib/tracker/gh-issue-create.sh, never
# through `gh issue create` (GraphQL, which the fleet's accounts rate-limit).
#
#   H1-H8   the helper contract, against a fake `gh` that records its argv
#   H9-H10  the real bin/run-decompose.sh files its children through it, and
#           the $GHLOG and DRYRUN lines keep the bytes they had
#   H11     tests/lib/gh-cli-rest-adapter.sh serves the REST create from a
#           CLI-shaped stub's own `issue create` arm
#   B1-B3   the ban: no live `gh issue create` in bin/ or worker/
#
# No network, no token, nothing written outside $T.
#   HARNESS_TEST_SANDBOX=1 bash tests/gh-issue-create.bh-8962-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
SRC=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "jq missing — skipping"; exit 0; }

LIB="$SRC/bin/lib/tracker/gh-issue-create.sh"
ADAPTER="$SRC/tests/lib/gh-cli-rest-adapter.sh"

# ---------------------------------------------------------------------------
# The fake gh: one arg per line to $GHF_ARGV (calls split by a `--call--`
# line), stdout $GHF_OUT, stderr $GHF_ERR, rc $GHF_RC. The fake timeout logs
# its bound and runs the rest.
mkdir -p "$T/fb"
cat > "$T/fb/gh" <<'SH'
#!/bin/bash
{ echo -- --call--; for a in "$@"; do printf '%s\n' "$a"; done; } >> "$GHF_ARGV"
[ -n "${GHF_OUT:-}" ] && printf '%s\n' "$GHF_OUT"
[ -n "${GHF_ERR:-}" ] && printf '%s\n' "$GHF_ERR" >&2
exit "${GHF_RC:-0}"
SH
cat > "$T/fb/timeout" <<'SH'
#!/bin/bash
printf 'timeout %s\n' "$1" >> "$GHF_TIMEOUT"
shift
exec "$@"
SH
chmod +x "$T/fb/gh" "$T/fb/timeout"
export GHF_ARGV="$T/argv" GHF_TIMEOUT="$T/timeout.log"
printf 'the body\n' > "$T/body.md"
OK_JSON='{"number":12,"html_url":"https://github.com/o/r/issues/12"}'

# hcall <args...> — run the helper in a fresh shell on the fake PATH. Prints
# rc=, out=, err=, num=, url= lines.
hcall() {
  : > "$GHF_ARGV"; : > "$GHF_TIMEOUT"
  PATH="$T/fb:$PATH" bash -c '
    . "$1" || exit 99; shift
    o=$(mktemp); e=$(mktemp); rc=0
    gh_issue_create "$@" > "$o" 2> "$e" || rc=$?
    printf "rc=%s\nout=%s\nerr=%s\nnum=%s\nurl=%s\n" "$rc" "$(cat "$o")" "$(cat "$e")" "${GH_ISSUE_NUMBER-unset}" "${GH_ISSUE_URL-unset}"
    rm -f "$o" "$e"' _ "$LIB" "$@"
}
field() { sed -n "s/^$1=//p" <<<"$2"; }
argv_of() { sed '1d' "$GHF_ARGV" | paste -sd' ' -; }

[ -r "$LIB" ] && ok || bad "H0: bin/lib/tracker/gh-issue-create.sh is missing"
bash -n "$LIB" 2>/dev/null && ok || bad "H0: bash -n on the helper"
SO=$(bash -c 'set -u; . "$1"; echo SOURCED' _ "$LIB" 2>&1)
[ "$SO" = SOURCED ] && ok || bad "H0: sourcing prints nothing and returns 0 (got '$SO')"

# H1 bad args: rc 1, one stderr line, and no request.
for C in "o|T|$T/body.md|repo" "o/r||$T/body.md|title" "o/r|T|$T/nope.md|body"; do
  IFS='|' read -r A1 A2 A3 WHY <<<"$C"
  R=$(hcall "$A1" "$A2" "$A3")
  [ "$(field rc "$R")" = 1 ] && ok || bad "H1[$WHY]: rc 1 ($R)"
  E=$(field err "$R")
  { [ -n "$E" ] && [ "$(printf '%s\n' "$E" | wc -l)" -eq 1 ] && grep -q "bad args ($WHY)" <<<"$E"; } \
    && ok || bad "H1[$WHY]: one stderr line naming $WHY (got '$E')"
  [ -s "$GHF_ARGV" ] && bad "H1[$WHY]: no request on bad args ($(cat "$GHF_ARGV"))" || ok
done

# H2 success: the argv, the URL on stdout, the number in the global.
R=$(GHF_OUT="$OK_JSON" hcall o/r T "$T/body.md")
[ "$(field rc "$R")" = 0 ] && ok || bad "H2: rc 0 ($R)"
[ "$(argv_of)" = "api -X POST repos/o/r/issues -f title=T -F body=@$T/body.md" ] \
  && ok || bad "H2: argv is the REST create (got '$(argv_of)')"
grep -qx -- '--body' "$GHF_ARGV" && bad "H2: the body never travels as --body" || ok
[ "$(field out "$R")" = "https://github.com/o/r/issues/12" ] && ok || bad "H2: stdout is the html_url ($R)"
[ "$(field num "$R")" = 12 ] && ok || bad "H2: GH_ISSUE_NUMBER=12 ($R)"
[ "$(field url "$R")" = "https://github.com/o/r/issues/12" ] && ok || bad "H2: GH_ISSUE_URL set ($R)"
[ -z "$(field err "$R")" ] && ok || bad "H2: nothing on stderr ($R)"

# H3 labels: repeated labels[] in order; none or an empty one adds nothing.
R=$(GHF_OUT="$OK_JSON" hcall o/r T "$T/body.md" ai-build hotfix)
[ "$(argv_of)" = "api -X POST repos/o/r/issues -f title=T -F body=@$T/body.md -f labels[]=ai-build -f labels[]=hotfix" ] \
  && ok || bad "H3: two labels[] in order (got '$(argv_of)')"
R=$(GHF_OUT="$OK_JSON" hcall o/r T "$T/body.md" "")
grep -q 'labels' "$GHF_ARGV" && bad "H3: an empty label adds no labels[] ($(argv_of))" || ok
[ "$(field rc "$R")" = 0 ] && ok || bad "H3: rc 0 with an empty label ($R)"

# H4 the number comes from .number, not the URL text.
R=$(GHF_OUT='{"number":13,"html_url":"https://github.com/o/r/issues/99"}' hcall o/r T "$T/body.md")
[ "$(field num "$R")" = 13 ] && ok || bad "H4: GH_ISSUE_NUMBER is .number 13 ($R)"
[ "$(field out "$R")" = "https://github.com/o/r/issues/99" ] && ok || bad "H4: stdout is .html_url ($R)"

# H5 API failure: rc 1, the API message on stderr, nothing on stdout.
R=$(GHF_OUT='{"message":"Validation Failed"}' GHF_ERR='gh: Validation Failed (HTTP 422)' GHF_RC=1 hcall o/r T "$T/body.md")
[ "$(field rc "$R")" = 1 ] && ok || bad "H5: rc 1 on a 422 ($R)"
grep -q 'Validation Failed' <<<"$(field err "$R")" && ok || bad "H5: stderr has the API message ($R)"
[ -z "$(field out "$R")" ] && ok || bad "H5: stdout is empty on failure ($R)"
[ -z "$(field num "$R")" ] && ok || bad "H5: GH_ISSUE_NUMBER empty on failure ($R)"
R=$(GHF_ERR='gh: HTTP 502' GHF_RC=1 hcall o/r T "$T/body.md")
[ "$(field rc "$R")" = 1 ] && ok || bad "H5b: rc 1 on a 502 ($R)"
grep -q 'HTTP 502' <<<"$(field err "$R")" && ok || bad "H5b: stderr falls back to gh's stderr ($R)"

# H6 rc 0 but no number: a failure.
for J in '{}' '{"number":0,"html_url":"https://github.com/o/r/issues/0"}' '' '{"number":5}'; do
  R=$(GHF_OUT="$J" hcall o/r T "$T/body.md")
  [ "$(field rc "$R")" = 1 ] && ok || bad "H6[$J]: rc 1 ($R)"
  grep -q 'no issue number' <<<"$(field err "$R")" && ok || bad "H6[$J]: says no issue number ($R)"
  [ -z "$(field num "$R")" ] && ok || bad "H6[$J]: GH_ISSUE_NUMBER empty ($R)"
done
# A failing call after a good one clears the globals.
: > "$GHF_ARGV"
R=$(PATH="$T/fb:$PATH" bash -c '
  . "$1"
  GHF_OUT="$2" gh_issue_create o/r T "$3" >/dev/null 2>&1
  GHF_OUT="" GHF_RC=1 gh_issue_create o/r T "$3" >/dev/null 2>&1
  printf "num=%s\nurl=%s\n" "$GH_ISSUE_NUMBER" "$GH_ISSUE_URL"' _ "$LIB" "$OK_JSON" "$T/body.md")
[ "$(field num "$R")" = "" ] && [ "$(field url "$R")" = "" ] && ok || bad "H6: a failed call leaves no old number ($R)"

# H7 the opt-in timeout bound.
R=$(GHF_OUT="$OK_JSON" GH_ISSUE_CREATE_TIMEOUT_S=60 hcall o/r T "$T/body.md")
[ "$(cat "$GHF_TIMEOUT")" = "timeout 60" ] && ok || bad "H7: runs under timeout 60 (got '$(cat "$GHF_TIMEOUT")')"
[ "$(field num "$R")" = 12 ] && ok || bad "H7: still files under the bound ($R)"
for V in "" abc 0; do
  R=$(GHF_OUT="$OK_JSON" GH_ISSUE_CREATE_TIMEOUT_S="$V" hcall o/r T "$T/body.md")
  [ -s "$GHF_TIMEOUT" ] && bad "H7['$V']: no timeout ($(cat "$GHF_TIMEOUT"))" || ok
done

# H8 errexit-safe and never exits the caller.
R=$(PATH="$T/fb:$PATH" GHF_OUT="$OK_JSON" bash -c 'set -euo pipefail; . "$1"; gh_issue_create o/r T "$2" >/dev/null; echo "ALIVE $GH_ISSUE_NUMBER"' _ "$LIB" "$T/body.md" 2>&1)
[ "$R" = "ALIVE 12" ] && ok || bad "H8: success path under set -euo pipefail (got '$R')"
R=$(PATH="$T/fb:$PATH" GHF_RC=1 GHF_ERR='gh: HTTP 500' bash -c 'set -euo pipefail; . "$1"; if gh_issue_create o/r T "$2" 2>/dev/null; then echo WRONG; else echo "FAILED rc=$?"; fi; echo ALIVE' _ "$LIB" "$T/body.md" 2>&1)
[ "$R" = "$(printf 'FAILED rc=1\nALIVE')" ] && ok || bad "H8: failure is rc 1, the shell goes on (got '$R')"
R=$(PATH="$T/fb:$PATH" GHF_RC=1 bash -c '. "$1"; gh_issue_create o/r T "$2" 2>/dev/null; echo "ALIVE $?"' _ "$LIB" "$T/body.md" 2>&1)
[ "$R" = "ALIVE 1" ] && ok || bad "H8: the helper never exits its caller (got '$R')"

# ---------------------------------------------------------------------------
# H9/H10 the real bin/run-decompose.sh, in a scratch closure.
H="$T/h"
mkdir -p "$H/bin/lib" "$H/logs" "$H/env" "$H/prompts" "$T/dfb"
scratch_install_closure bin/run-decompose.sh "$H" >/dev/null || bad "H9: scratch_install_closure run-decompose.sh"
scratch_install_closure bin/fleet-conf.sh "$H" >/dev/null || bad "H9: scratch_install_closure fleet-conf.sh"
[ -r "$H/bin/lib/tracker/gh-issue-create.sh" ] && ok || bad "H9: the scratch closure carries the helper (fc-issues sources it)"
. "$SRC/tests/lib/model-route-stub.sh" || exit 1; model_routes_fixture "$H" scoutish || exit 1
cat > "$H/fleet.conf" <<'CONF'
# <project> <repo> <prod> <board-api-prefix> <offset> [box] [ip]
scoutish   example-org/scoutish   https://scoutish.example  -  9 box-1 192.0.2.9
CONF
cat > "$H/bin/agent-call.sh" <<'SH'
#!/bin/bash
exit 0
SH
chmod +x "$H/bin/agent-call.sh"
SPEC='[
 {"title":"metrics table","contract":"src/db/metrics.ts: MetricRow","after":[],"body":"Create the table.\n\nFiles: src/db/metrics.ts\n\n## Observable outcome\nThe slice acceptance test passes end to end."},
 {"title":"dashboard tile","after":[],"body":"Render the tile.\n\nFiles: src/app/MetricTile.tsx\n\n## Observable outcome\nThe slice acceptance test passes end to end."}
]'
cat > "$T/dfb/gh" <<'SH'
#!/bin/bash
echo "$*" >> "$GH_CALLS"
. "$ADAPTER" || exit 1
gh_cli_rest_create "$0" "$@" && exit 0
_env() { printf 'HTTP/2.0 %s\r\n\r\n%s\n' "$1" "$2"; }
case "$*" in
  *"-i -X GET repos/example-org/scoutish/issues/552"*) _env 200 '{"labels":[{"name":"ai-build"}]}'; exit 0 ;;
  *"-i -X DELETE "*) _env 200 '[]'; exit 0 ;;
  *"-i -X POST "*) _env 201 '{"id":1}'; exit 0 ;;
esac
case "$1 $2" in
  "issue create")
    n=$(( 800 + $(grep -c '^issue create' "$GH_CALLS") ))
    echo "https://github.com/example-org/scoutish/issues/$n" ;;
esac
exit 0
SH
chmod +x "$T/dfb/gh"
drive() {
  mkdir -p "$T/b"; rm -f "$T/b/children.txt" "$T/b/decompose-gh.log"
  printf '%s\n' "$SPEC" > "$T/b/children.json"
  printf 'SIZE_DECLARED: files=18 lines=1900\nSIZE_OVER: lines=1900>300\nSIZE_VERDICT: over\n' > "$T/b/size-gate.txt"
  : > "$T/gh.calls"; : > "$T/b/pipeline.log"
  env HARNESS="$H" FLEET_CONF="$H/fleet.conf" GH_CALLS="$T/gh.calls" ADAPTER="$ADAPTER" GH_ETAG=0 \
      PATH="$T/dfb:$PATH" "$@" "$H/bin/run-decompose.sh" scoutish 552 TK-552 "$T/b" 300 12 2>&1
}
OUT=$(drive); RC=$?
[ "$RC" -eq 0 ] && ok || bad "H9: run-decompose rc 0 (rc=$RC: $(tail -5 <<<"$OUT") $(tail -3 "$T/b/pipeline.log") $(cat "$T/b/decompose-run.txt" 2>/dev/null | tail -3))"
[ "$(grep -c '^api -X POST repos/example-org/scoutish/issues -f title=' "$T/gh.calls")" -eq 2 ] \
  && ok || bad "H9: two REST creates ($(cat "$T/gh.calls"))"
[ "$(grep -c '^issue create' "$T/gh.calls")" -eq 2 ] && ok || bad "H9: the stub's create arm ran once per POST, through the adapter"
POSTS=$(grep -c '^api -X POST repos/example-org/scoutish/issues ' "$T/gh.calls")
CREATES=$(grep -n '' "$T/gh.calls" | grep -E '^[0-9]+:(issue create|api -X POST repos/[^ ]+/issues )' | cut -d: -f2- | cut -c1-12 | paste -sd'|' -)
[ "$POSTS" = 2 ] && [ "$CREATES" = "api -X POST |issue create|api -X POST |issue create" ] \
  && ok || bad "H9: every issue create follows a REST POST, none runs on its own ($CREATES)"
grep -q -- '-f labels\[\]=ai-build' "$T/gh.calls" && ok || bad "H9: the ai-build label travels as labels[]"
[ "$(cat "$T/b/children.txt" 2>/dev/null | paste -sd' ' -)" = "TK-801 TK-802" ] \
  && ok || bad "H9: children.txt holds the two numbers ($(cat "$T/b/children.txt" 2>/dev/null))"
# H10 the $GHLOG line is the bytes it was on main.
grep -qE "^gh issue create -R example-org/scoutish --title 'TK-552\\.1: dashboard tile' --label ai-build --body-file /" "$T/b/decompose-gh.log" \
  && ok || bad "H10: GHLOG keeps its gh issue create line ($(cat "$T/b/decompose-gh.log" 2>/dev/null))"
OUT=$(drive DECOMPOSE_DRY_RUN=1); RC=$?
[ "$RC" -eq 0 ] && ok || bad "H10: dry run rc 0 ($RC)"
grep -qE "^DRYRUN gh issue create -R example-org/scoutish --title 'TK-552\\.0: contract — metrics table' --label ai-build --body-file /" <<<"$OUT" \
  && ok || bad "H10: the DRYRUN line keeps its bytes ($(grep DRYRUN <<<"$OUT" | head -2))"
grep -q -- '-X POST repos/example-org/scoutish/issues ' "$T/gh.calls" && bad "H10: a dry run sends no create" || ok
# A failed POST: rc non-zero, the FC_ERROR prefix, nothing recorded.
sed 's#echo "https://github.com/example-org/scoutish/issues/$n" ;;#echo "HTTP 502: fixture create failure"; exit 1 ;;#' "$T/dfb/gh" > "$T/dfb/gh.fail"
mv "$T/dfb/gh" "$T/dfb/gh.ok"; mv "$T/dfb/gh.fail" "$T/dfb/gh"; chmod +x "$T/dfb/gh"
OUT=$(drive); RC=$?
[ "$RC" -ne 0 ] && ok || bad "H9f: a failed create fails the split"
grep -q 'gh issue create failed on child 1 of 2: .*fixture create failure.*missing children: child 1, child 2' "$T/b/pipeline.log" \
  && ok || bad "H9f: FC_ERROR keeps its prefix and carries the API message ($(grep -i 'failed' "$T/b/pipeline.log" | head -2))"
[ -s "$T/b/children.txt" ] && bad "H9f: nothing recorded ($(cat "$T/b/children.txt"))" || ok
mv "$T/dfb/gh.ok" "$T/dfb/gh"

# ---------------------------------------------------------------------------
# H11 the adapter route.
cat > "$T/fb/stub" <<'SH'
#!/bin/bash
echo "$*" >> "$STUB_LOG"
. "$ADAPTER" || exit 1
if [ "${STUB_POST:-1}" = 1 ]; then gh_cli_rest "$0" post "$@" && exit 0
else gh_cli_rest "$0" "$@" && exit 0; fi
case "$1 $2" in
  "issue create") [ "${STUB_FAIL:-0}" = 1 ] && { echo "could not add label: 'x' not found"; exit 1; }
                  echo "https://github.com/o/r/issues/7" ;;
  *) echo "UNSERVED $*" ;;
esac
SH
chmod +x "$T/fb/stub"
export STUB_LOG="$T/stub.log" ADAPTER
: > "$STUB_LOG"
O=$("$T/fb/stub" api -X POST repos/o/r/issues -f title=T -F body=@F -f 'labels[]=x'); RC=$?
[ "$RC" -eq 0 ] && ok || bad "H11: rc 0 ($RC $O)"
grep -qx 'issue create -R o/r --title T --label x --body-file F' "$STUB_LOG" && ok || bad "H11: the stub's create arm got the CLI argv ($(cat "$STUB_LOG"))"
[ "$(jq -r '.number' <<<"$O" 2>/dev/null)" = 7 ] && [ "$(jq -r '.html_url' <<<"$O" 2>/dev/null)" = "https://github.com/o/r/issues/7" ] \
  && ok || bad "H11: the adapter answers the REST JSON ($O)"
: > "$STUB_LOG"
O=$(STUB_POST=0 "$T/fb/stub" api -X POST repos/o/r/issues -f title=T -F body=@F)
grep -q '^UNSERVED' <<<"$O" && ok || bad "H11: without post the adapter does not serve the create ($O)"
: > "$STUB_LOG"
O=$(STUB_FAIL=1 "$T/fb/stub" api -X POST repos/o/r/issues -f title=T -F body=@F -f 'labels[]=x' 2>"$T/stub.err"); RC=$?
[ "$RC" -eq 1 ] && ok || bad "H11: a failing stub create exits 1 ($RC)"
[ "$(jq -r '.message' <<<"$O" 2>/dev/null)" = "could not add label: 'x' not found" ] && ok || bad "H11: the failure body is the message JSON ($O)"
grep -q 'HTTP 422' "$T/stub.err" && ok || bad "H11: stderr names an HTTP status ($(cat "$T/stub.err"))"
for A in "api -i -X POST repos/o/r/issues/7/comments -F body=@F" "api -X POST repos/o/r/issues/7/labels -f labels[]=x" "api -X GET repos/o/r/issues"; do
  : > "$STUB_LOG"
  # shellcheck disable=SC2086 # the argv is split on purpose
  O=$(bash -c '. "$1"; shift; gh_cli_rest_create "$@"; echo "rc=$?"' _ "$ADAPTER" "$T/fb/stub" $A 2>/dev/null)
  [ "$O" = "rc=1" ] && ok || bad "H11: gh_cli_rest_create does not serve '$A' ($O)"
done
# A stub with no shebang runs under /bin/sh when timeout execs it, so the
# adapter must source there too (fc-issues.bh-982's launcher stub does).
R=$(sh -c '. "$1" && command -v gh_cli_rest_create >/dev/null && echo SOURCED' _ "$ADAPTER" 2>&1)
[ "$R" = SOURCED ] && ok || bad "H11: the adapter sources under /bin/sh ($R)"
# The helper itself, end to end through the adapter.
cat > "$T/fb/gh-adapted" <<'SH'
#!/bin/bash
. "$ADAPTER" || exit 1
gh_cli_rest_create "$0" "$@" && exit 0
[ "$1 $2" = "issue create" ] && echo "https://github.com/o/r/issues/31"
SH
mkdir -p "$T/fb2"; mv "$T/fb/gh-adapted" "$T/fb2/gh"; chmod +x "$T/fb2/gh"
R=$(PATH="$T/fb2:$PATH" bash -c '. "$1"; gh_issue_create o/r T "$2" ai-build; echo "num=$GH_ISSUE_NUMBER"' _ "$LIB" "$T/body.md")
[ "$R" = "$(printf 'https://github.com/o/r/issues/31\nnum=31')" ] && ok || bad "H11: helper + adapter round trip ($R)"

# ---------------------------------------------------------------------------
# B1-B3 the ban ratchet.
# ghic_scan <tree> — `path:line:text` for every LIVE `gh issue create` under
# <tree>/bin and <tree>/worker. Not live: a line whose first non-blank is `#`
# or `--`; a hit inside an open quote (an echo, die, printf or log string),
# unless the text before it ends in a command substitution. Live: the text
# before the hit, trailing blanks removed, is empty or ends in a command
# position: `$(`, a backtick, ; && || | ( { then do else if !, or `timeout N`.
ghic_scan() {
  local tree="$1" f
  for f in $(cd "$tree" && grep -rlF 'gh issue create' --exclude-dir=node_modules bin worker 2>/dev/null | sort); do
    awk -v rel="$f" '
      index($0, "gh issue create") == 0 { next }
      /^[[:space:]]*(#|--)/ { next }
      {
        pre = substr($0, 1, index($0, "gh issue create") - 1)
        sub(/[[:space:]]+$/, "", pre)
        if (pre ~ /(\$\(|`)$/) { print rel ":" FNR ":" $0; next }
        q = pre; nd = gsub(/"/, "", q); q = pre; ns = gsub(/\047/, "", q)
        if (nd % 2 == 1 || ns % 2 == 1) next
        if (pre == "" || pre ~ /(;|&&|\|\||\||\(|\{|!)$/ || pre ~ /(^|[^A-Za-z0-9_])(then|do|else|if)$/ || pre ~ /(^|[^A-Za-z0-9_])timeout[[:space:]]+[0-9]+[smh]?$/)
          print rel ":" FNR ":" $0
      }' "$tree/$f"
  done
}
LIVE=$(ghic_scan "$SRC")
[ -z "$LIVE" ] && echo "PASS: B1" && ok || bad "B1: live gh issue create calls in bin/ or worker/ (use gh_issue_create, bin/lib/tracker/gh-issue-create.sh):
$LIVE"

# B2 the shapes, on a fixture tree.
mkdir -p "$T/fx/bin" "$T/fx/worker"
b2() { # b2 <expected count> <line>
  printf '%s\n' "$2" > "$T/fx/bin/x.sh"
  local n; n=$(ghic_scan "$T/fx" | grep -c .)
  [ "$n" = "$1" ] && echo "PASS: B2 [$2]" && ok || bad "B2: '$2' must count $1, counted $n"
}
b2 1 'url=$(gh issue create -R x --title t)'
b2 1 '      gh issue create -R "$S" --title "$T" --body-file "$F" \'
b2 1 'url=$(timeout 60 gh issue create -R "$s" --title t)'
b2 1 'x && gh issue create -R x'
b2 1 'if gh issue create -R x; then :; fi'
b2 1 'x="$(gh issue create -R x)"'
b2 0 '# gh issue create -R x'
b2 0 "printf 'DRYRUN gh issue create -R %s'"
b2 0 '      || die "gh issue create failed for up10"'
b2 0 '-- `gh issue create` from a build'
b2 0 '  echo "gh issue create refused: ticket"'
b2 0 '    _pmv_log "MISMATCH: x not filed (gh issue create gave no issue number)"'
b2 0 '  gh_issue_create "$repo" "t" "$f" ai-build'
printf '%s\n' '-- gh issue create in SQL' > "$T/fx/worker/a.sql"; printf 'url=$(gh issue create -R x)\n' > "$T/fx/worker/b.js"
mkdir -p "$T/fx/worker/node_modules/z"; printf 'gh issue create -R x\n' > "$T/fx/worker/node_modules/z/c.sh"
: > "$T/fx/bin/x.sh"
[ "$(ghic_scan "$T/fx" | cut -d: -f1 | paste -sd' ' -)" = "worker/b.js" ] && echo "PASS: B2 worker" && ok \
  || bad "B2: worker/ is scanned, node_modules is not ($(ghic_scan "$T/fx"))"

# B3 the scan is red on the base this ticket started from (main @ 42f873fb9).
BASE_SHA=$(git -C "$SRC" rev-parse -q --verify "42f873fb9ecbd5f00550930ecb9936c1634d83f2^{commit}" 2>/dev/null || true)
if [ -z "$BASE_SHA" ]; then
  echo "SKIP: B3 — commit 42f873fb9 is not in this clone (shallow history); B1/B2 still pin the ban"
else
  mkdir -p "$T/base"
  if git -C "$SRC" archive "$BASE_SHA" bin worker 2>/dev/null | tar -x -C "$T/base" 2>/dev/null; then
    N=$(ghic_scan "$T/base" | grep -c .)
    [ "$N" = 5 ] && echo "PASS: B3 (5 live calls on the base)" && ok || bad "B3: the base must show exactly 5 live calls, got $N:
$(ghic_scan "$T/base")"
  else
    bad "B3: git archive of $BASE_SHA failed"
  fi
fi

echo "gh-issue-create.bh-8962: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
