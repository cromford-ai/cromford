#!/bin/bash
# tests/trk-prompt-render.bh-8450-test.sh — BH-8450 (slice C2 of #7920): the
# watcher-prompt render (_obs_prompt_render in bin/lib/onboard-stations.sh)
# emits bin/trk commands when tracker_kind is jira or linear.
#
# Each case is its own scratch checkout $T/<case>/R holding the real
# prompts/TEMPLATE-GH.md and prompts/_template/trk-commands.md, the real
# tracker contract lib with its closure, bin/jobs-client.sh and
# bin/fleet-conf.sh, and a stub bin/render-crontab.sh. A curl stub plays the
# jobs worker's settings route (tests/lib/trk-linear-stub.bh-8450.sh). The
# case sources the REAL bin/lib/onboard-stations.sh and calls
# _obs_prompt_render, the function bin/load-project.sh runs.
#
#   R1  a linear row: trk commands, header `(Linear tracker)`, no gh issue
#       line, no placeholder left
#   R2  a jira row: the same, `(Jira tracker)`
#   R3  no row (fleet.conf `-`), a board project, a refused row `Linear`: the
#       prompt is byte for byte the GitHub render
#   R4  a template with no `- Close on shipped:` line, linear row: rc 1 and no
#       prompt file; the same with no fragment file
#   R5  an existing prompts/<p>.md with a linear row is left alone
#
#   HARNESS_TEST_SANDBOX=1 bash tests/trk-prompt-render.bh-8450-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/trk-linear-stub.bh-8450.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null 2>&1 || { echo "jq missing — skipping"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "python3 missing — skipping"; exit 0; }
LIB="$DIR/bin/lib/onboard-stations.sh"
TPL="$DIR/prompts/TEMPLATE-GH.md"
FRAG="$DIR/prompts/_template/trk-commands.md"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL $1"; }
trk_stub_install "$T/stub" || { echo "FAIL could not install the stubs"; exit 1; }

# mk <case> [<row value>]: a scratch checkout; the row is
# tracker_adapter.newp (no value = no row).
mk() {
  local C="$T/$1"
  mkdir -p "$C/R/bin" "$C/R/prompts/_template" "$C/ls"
  ( cd "$DIR" && for s in bin/lib/tracker.sh bin/jobs-client.sh bin/fleet-conf.sh bin/lib/cron-lines.sh; do
      scratch_install_closure "$s" "$C/R" || exit 1; done ) >/dev/null || { bad "$1 could not install the closure"; return 1; }
  cp "$TPL" "$C/R/prompts/"
  [ -r "$FRAG" ] && cp "$FRAG" "$C/R/prompts/_template/"
  cat > "$C/R/fleet.conf" <<'CONF'
# <project> <repo> <prod> <board-api-prefix> <offset>
newp   Acme/newp  https://newp.example  -     9
boardp Acme/bp    https://bp.example    /bp   8
CONF
  printf '#!/bin/bash\necho "*/5 * * * * run newp"\n' > "$C/R/bin/render-crontab.sh"
  chmod +x "$C/R/bin/render-crontab.sh"
  [ -n "${2:-}" ] && printf '200\n{"setting":{"key":"tracker_adapter.%s","value":"%s"}}\n' "${3:-newp}" "$2" \
    > "$C/ls/setting-tracker_adapter.${3:-newp}"
  return 0
}
# render <case> [<project>]: the real lib in a subshell in the checkout; output
# in $C/out, the true rc in RC.
render() {
  local C="$T/$1" p="${2:-newp}"
  RC=0
  (
    cd "$C/R" || exit 99
    unset H HARNESS_ENV_DIR HARNESS_SECRET CONTEXT_FILE PREFIX_LC TRK_DRY
    export HARNESS="$C/R" FLEET_CONF="$C/R/fleet.conf" PATH="$T/stub:$PATH" TL_STATE="$C/ls" TL_FIX=/nonexistent
    export HARNESS_SECRET=hs-fixture-8450 JOBS_URL=https://jobs.example JOBS_RETRIES=0
    PROJECT="$p" SLUG=Acme/newp PROD=https://newp.example BOX=zzz-box PREFIX=NP BASE=main
    # shellcheck source=bin/lib/onboard-stations.sh
    . "$LIB" || exit 98
    _obs_prompt_render
  ) > "$C/out" 2>&1 || RC=$?
}
# github_ref <case> <project>: the GitHub render, computed here from the
# template on its own (line 0 replaced, the placeholders filled).
github_ref() {
  python3 - "$2" <<'PY'
import sys
p = sys.argv[1]
t = open('prompts/TEMPLATE-GH.md').read().split('\n')
t[0] = f'# Triage run — {p} (GitHub Issues board)'
t = '\n'.join(t).replace('<CONTEXT>', '')
for a, b in [('<PROJECT>', p), ('<REPO_SLUG>', 'Acme/newp'), ('<PROD_URL>', 'https://newp.example'),
             ('<KEY_PREFIX_LC>', 'np'), ('<key_prefix_lc>', 'np'), ('<KEY_PREFIX>', 'NP'), ('<BASE_BRANCH>', 'main')]:
    t = t.replace(a, b)
sys.stdout.write(t)
PY
}

[ -r "$FRAG" ] && ok "R0 the fragment prompts/_template/trk-commands.md exists" || bad "R0 no fragment at $FRAG"

# ---- R1 / R2 ------------------------------------------------------------------
for k in linear:Linear jira:Jira; do
  kind="${k%%:*}"; name="${k#*:}"; c="r-$kind"
  mk "$c" "$kind"; render "$c"
  P="$T/$c/R/prompts/newp.md"
  [ "$RC" = 0 ] && [ -s "$P" ] && ok "R $kind render rc 0 with a prompt" || { bad "R $kind rc $RC: $(cat "$T/$c/out")"; continue; }
  grep -qF "prompts/newp.md rendered (trk commands, tracker $kind)" "$T/$c/out" && ok "R $kind says it rendered trk commands" \
    || bad "R $kind output: $(cat "$T/$c/out")"
  [ "$(head -1 "$P")" = "# Triage run — newp ($name tracker)" ] && ok "R $kind header names the $name tracker" || bad "R $kind header: $(head -1 "$P")"
  for s in "/root/harness/bin/trk list newp" "/root/harness/bin/trk read newp <KEY>" "/root/harness/bin/trk comment newp <KEY>" \
           "/root/harness/bin/trk close-out newp <KEY>" "/root/harness/bin/trk transition newp <KEY>" "**$name**" "Acme/newp" \
           "UNTRUSTED INPUT"; do
    grep -qF -- "$s" "$P" && ok "R $kind prompt has '$s'" || bad "R $kind prompt lacks '$s'"
  done
  grep -q 'gh issue' "$P" && bad "R $kind prompt still has a gh issue line: $(grep -n 'gh issue' "$P")" || ok "R $kind no gh issue line"
  grep -qF 'GitHub Issues on the app repo' "$P" && bad "R $kind still says the board is GitHub Issues" || ok "R $kind no GitHub Issues board text"
  grep -qE '<PROJECT>|<REPO_SLUG>|<TRACKER_NAME>' "$P" && bad "R $kind a placeholder is left: $(grep -nE '<PROJECT>|<REPO_SLUG>|<TRACKER_NAME>' "$P")" \
    || ok "R $kind every placeholder is filled"
  grep -qF '## THE PRIME RULE' "$P" && grep -qF '## Logging' "$P" && ok "R $kind the rest of the template is kept" || bad "R $kind lost template sections"
  grep -qF "This project's tickets live in **$name**" "$P" && ok "R $kind the fragment says where the tickets live" || bad "R $kind fragment text"
done

# ---- R3 the GitHub render, byte for byte ---------------------------------------
r3() { # r3 <label> <case> <project>
  render "$2" "$3"
  local P="$T/$2/R/prompts/$3.md"
  [ "$RC" = 0 ] && [ -s "$P" ] || { bad "R3 $1 rc $RC: $(cat "$T/$2/out")"; return; }
  if [ "$(cd "$T/$2/R" && github_ref "$2" "$3" | sha256sum)" = "$(sha256sum < "$P")" ]; then ok "R3 $1 is the GitHub render byte for byte"
  else bad "R3 $1 differs from the GitHub render: $(cd "$T/$2/R" && diff <(github_ref "$2" "$3") "$P" | head -20)"; fi
  grep -qxF "prompts/$3.md rendered" "$T/$2/out" && ok "R3 $1 prints the plain rendered line" || bad "R3 $1 output: $(cat "$T/$2/out")"
}
mk r3-norow; r3 "no row (fleet.conf -)" r3-norow newp
mk r3-gh github-issues; r3 "a github-issues row" r3-gh newp
mk r3-board; r3 "a board project" r3-board boardp
mk r3-refused Linear; r3 "a refused row Linear" r3-refused newp
grep -q 'settings/tracker_adapter.newp' "$T/r3-refused/ls/jobs.log" 2>/dev/null && ok "R3 the refused row was asked for" \
  || bad "R3 the row was never read: $(cat "$T/r3-refused/ls/jobs.log" 2>/dev/null)"

# ---- R4 a failed trk render writes no prompt ------------------------------------
mk r4 linear
grep -v '^- Close on shipped:' "$T/r4/R/prompts/TEMPLATE-GH.md" > "$T/r4/tpl" && mv "$T/r4/tpl" "$T/r4/R/prompts/TEMPLATE-GH.md"
render r4
[ "$RC" != 0 ] && [ ! -e "$T/r4/R/prompts/newp.md" ] && ok "R4 no Close line: rc $RC and no prompt file" \
  || bad "R4 rc $RC, prompt exists: $([ -e "$T/r4/R/prompts/newp.md" ] && echo yes || echo no)"
mk r4-frag linear; rm -f "$T/r4-frag/R/prompts/_template/trk-commands.md"
render r4-frag
[ "$RC" != 0 ] && [ ! -e "$T/r4-frag/R/prompts/newp.md" ] && ok "R4 no fragment: rc $RC and no prompt file" \
  || bad "R4 no fragment: rc $RC"

# ---- R5 an existing prompt is left alone -------------------------------------
mk r5 linear
printf 'hand-written prompt\n' > "$T/r5/R/prompts/newp.md"
render r5
[ "$RC" = 0 ] && [ "$(cat "$T/r5/R/prompts/newp.md")" = "hand-written prompt" ] && grep -qF "prompts/newp.md exists — skipping" "$T/r5/out" \
  && ok "R5 the existing prompt is unchanged" || bad "R5 rc $RC: $(cat "$T/r5/out")"

echo "trk-prompt-render.bh-8450: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
