#!/bin/bash
# tests/lane-stage-heredoc.bh-7841-test.sh — the lane-stage ratchet
# (tests/lib/lane-stage-check.py) reads `<<NAME` as a heredoc start only where
# bash does. A `<<NAME` inside '...' or "...", in a `<<<` here-string, in
# `$(( ))` arithmetic or in a comment must not drop the lines after it, so the
# agent-call site after it is still checked. A real heredoc body is still
# skipped. A heredoc still open at end of file is a FAIL with file and line.
#
#   bash tests/lane-stage-heredoc.bh-7841-test.sh          exit 0 = pass
# As root next to a live harness: HARNESS_TEST_SANDBOX=1 bash tests/…
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

command -v python3 >/dev/null || { echo "python3 missing — skipping"; exit 0; }
command -v jq      >/dev/null || { echo "jq missing — skipping"; exit 0; }
CHECKER="$(dirname "$0")/lib/lane-stage-check.py"
[ -r "$CHECKER" ] || { echo "FAIL: missing checker $CHECKER"; exit 1; }
check() { python3 "$CHECKER" "$@"; }

mksite() { # mksite <name> — a root with one bench/bench agent-call site bin/<name>.sh
  mkdir -p "$T/$1/catalog/lanes.d" "$T/$1/bin"
  jq -n --arg id "$1" \
    '{version:1, sites:[{id:$id, script:"bin/\($id).sh", kind:"agent-call", stage:"bench", project:"bench"}]}' \
    > "$T/$1/catalog/llm-sites.json"
}
run() { OUT=$(check "$T/$1" "$T/$1/catalog/lanes.d"); RC=$?; }
want_site() { # want_site <case> <label>
  [ "$RC" = 0 ] && grep -qx "SITE $1 stage=bench called=bench project=bench called_project=bench" <<<"$OUT" && ok \
    || bad "$(tr '[:lower:]' '[:upper:]' <<<"$1"): $2 (rc=$RC): $OUT"
}

# H1: `<<<NAME` inside single quotes.
mksite h1
cat > "$T/h1/bin/h1.sh" <<'EOF'
#!/bin/bash
printf 'x\n<<<UNTRUSTED\n'
"$H/bin/agent-call.sh" bench bench m 60 o x
EOF
run h1; want_site h1 "<<NAME in single quotes hid the site"

# H2: `<<EOF` inside double quotes.
mksite h2
cat > "$T/h2/bin/h2.sh" <<'EOF'
#!/bin/bash
echo "cat <<EOF here"
"$H/bin/agent-call.sh" bench bench m 60 o x
EOF
run h2; want_site h2 "<<NAME in double quotes hid the site"

# H3: a quoted heredoc echoed as text (the bin/remote-gate.sh shape).
mksite h3
cat > "$T/h3/bin/h3.sh" <<'EOF'
#!/bin/bash
echo "cat > \"\$R/suites\" <<'RG'"
"$H/bin/agent-call.sh" bench bench m 60 o x
EOF
run h3; want_site h3 "an echoed <<'RG' hid the site"

# H4: real heredocs are still skipped, every delimiter form.
mksite h4
printf '%s\n' '#!/bin/bash' \
  'cat <<EOF' '"$H/bin/agent-call.sh" triage bench m 1 o x' 'EOF' \
  'cat <<-EOF' '	"$H/bin/agent-call.sh" triage bench m 1 o x' '	EOF' \
  "cat <<'TXT'" '"$H/bin/agent-call.sh" triage bench m 1 o x' 'TXT' \
  'cat << "TXT"' '"$H/bin/agent-call.sh" triage bench m 1 o x' 'TXT' \
  '"$H/bin/agent-call.sh" bench bench m 60 o x' > "$T/h4/bin/h4.sh"
run h4; want_site h4 "a real heredoc body was read as a call"

# H5: near misses — a heredoc inside $( ) inside "...", a here-string,
# arithmetic and a comment.
mksite h5
cat > "$T/h5/bin/h5.sh" <<'EOF'
#!/bin/bash
read -r A B <<<"$(python3 - "$a" <<'PY'
"$H/bin/agent-call.sh" triage bench m 1 o x
PY
)"
grep -q x <<<"$v"
n=$(( 1 << n ))
# cat <<NEVER
"$H/bin/agent-call.sh" bench bench m 60 o x
EOF
run h5; want_site h5 "a here-string, arithmetic or comment was read as a heredoc, or a real one was not"
grep -q '^FAIL' <<<"$OUT" && bad "H5: unexpected FAIL: $OUT" || ok

# H6: a heredoc still open at end of file fails loud, once, with file and line.
mksite h6
printf '%s\n' '#!/bin/bash' 'echo start' 'cat <<EOF' '"$H/bin/agent-call.sh" bench bench m 60 o x' > "$T/h6/bin/h6.sh"
run h6
LINE='FAIL: bin/h6.sh:3: heredoc <<EOF opened here is never closed (end of file reached inside it)'
[ "$RC" = 1 ] && [ "$(grep -cxF "$LINE" <<<"$OUT")" = 1 ] && ! grep -q '^SKIP SITE h6' <<<"$OUT" && ok \
  || bad "H6: an unclosed heredoc did not fail exactly once with file and line (rc=$RC): $OUT"
# The lanes pass and the sites pass both scan one file: still one FAIL line.
jq -n '{id:"h6lane", script:"bin/h6.sh", stats:{cost_stage:"bench"}}' > "$T/h6/catalog/lanes.d/h6lane.json"
run h6
[ "$RC" = 1 ] && [ "$(grep -cxF "$LINE" <<<"$OUT")" = 1 ] && ok \
  || bad "H6: a file scanned by both passes did not print its unclosed-heredoc FAIL exactly once (rc=$RC): $OUT"

# H7: an escaped quote does not close the string.
mksite h7
cat > "$T/h7/bin/h7.sh" <<'EOF'
#!/bin/bash
echo "a \" <<EOF b"
"$H/bin/agent-call.sh" bench bench m 60 o x
EOF
run h7; want_site h7 "an escaped quote closed the string"

# H8: the real repo. bin/trap-eval.sh holds `'/^# <<< prompt_eval_grade/'`,
# which hid its agent-call site before this fix.
"$DIR/bin/llm-sites-build.sh" --compose --repo "$DIR" >/dev/null || { echo "FAIL: cannot compose catalog/llm-sites.json"; exit 1; }
OUT=$(check "$DIR" "$DIR/catalog/lanes.d"); RC=$?
[ "$RC" = 0 ] && grep -qx 'SITE trap-eval stage=trapeval called=trapeval project= called_project=trap-eval' <<<"$OUT" && ok \
  || bad "H8: the real repo fails, or trap-eval's site is not checked (rc=$RC): $(grep -E '^FAIL|trap-eval' <<<"$OUT")"

echo "lane-stage-heredoc: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
