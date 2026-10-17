#!/bin/bash
# tests/fly-envbundle-pool-nopat.bh-4798-test.sh — BH-4798 (2026-10-06): a box
# with no plain PAT must not stop every pool build at the env bundle, and the
# keyring logout must not be what takes that PAT away.
#
# THE INCIDENT. bin/ensure-box-gh-app-default.sh step 5 logged the small box's
# gh keyring out at 02:38Z. That login was the box's only plain PAT (no GH_TOKEN
# in env/global.env, no env/gh-pat), so `bin/gh-token.sh --pat` printed nothing
# and bin/fly-envbundle.sh died "bundle missing GH_TOKEN". bin/fly-pool.sh reads
# any bundle failure as "destroy, job stays queued", so every cromford and
# project-8 pool spawn failed, the main-red fix included. The pool
# never ships that PAT anyway: it swaps the line for a builders-App token.
#
# PINNED:
#   A  armed `fly-envbundle.sh <p> <dir> --pool` with no PAT: rc 0, a WARN, no
#      GH_TOKEN line; then fly-pool.sh's REAL swap block (lifted by its markers)
#      puts the App token in.
#   B  no third arg (fly-dispatch) with no PAT still dies, armed or not.
#   C  the swap block refuses the spawn when the mint ALSO fails and the bundle
#      has no PAT (destroy + unclaim, rc 1); with a PAT it still ships the PAT.
#   D  unarmed `--pool` with no PAT still dies; a junk third arg is a usage die.
#   E  ensure-box-gh-app-default.sh refuses the logout while the keyring is the
#      only plain PAT (rc 3, one --id alert naming env/gh-pat) and completes it
#      once env/gh-pat exists.
#   F  no fixture token value reaches any captured output, alert or log.
#
# Run from anywhere: bash tests/fly-envbundle-pool-nopat.bh-4798-test.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

H="$T/h"
mkdir -p "$H/bin/lib" "$H/env" "$H/logs" "$T/fake" "$T/cap"
for s in bin/fly-envbundle.sh bin/ensure-box-gh-app-default.sh; do
  scratch_install_closure "$s" "$H" >/dev/null || { echo "closure install failed for $s"; exit 1; }
done
cat > "$H/bin/fleet-conf.sh" <<'STUB'
#!/bin/bash
case "$1" in
  --tailnet-ip) echo local ;;
  *) [ "${2:-}" = repo ] && echo example-org/proj-repo ;;
esac
STUB
# gh-token.sh: --pat answers per PAT_MODE (pat | none); a mint answers the App
# token the ensure step requires.
cat > "$H/bin/gh-token.sh" <<'STUB'
#!/bin/bash
case " $* " in
  *" --pat "*) [ "${PAT_MODE:-none}" = pat ] && printf 'ghp_boxpatfixture\n'; exit 0 ;;
  *) printf 'ghs_ensurefixture\n' ;;
esac
STUB
cat > "$H/bin/lane-alert.sh" <<STUB
#!/bin/bash
printf '%s\n' "\$*" >> "$T/alerts.calls"
STUB
cat > "$T/fake/gh" <<STUB
#!/bin/bash
case "\$1 \$2" in
  "auth status") exit "\${FAKE_GH_STATUS:-0}" ;;
  "auth logout") echo logout >> "$T/logout.calls"; exit 0 ;;
  "auth token")  exit 1 ;;
  "api repos/"*) echo example-org/proj-repo; exit 0 ;;
esac
exit 1
STUB
chmod +x "$H/bin/"*.sh "$T/fake/gh"
printf 'BOARD_TOKEN=board-fixture\n' > "$H/env/proj.env"
arm()   { : > "$H/env/github-app.env"; }
unarm() { rm -f "$H/env/github-app.env"; }
base_global() { printf 'CLAUDE_CODE_OAUTH_TOKEN=oauth-fixture\nCONSOLE_URL=https://console.invalid\n' > "$H/env/global.env"; }
base_global

# run_eb <pat|none> <tag> [third arg]  -> rc in $RC, output dir $T/out-<tag>
run_eb() {
  local mode="$1" tag="$2"; shift 2
  rm -rf "$T/out-$tag"
  env -i PATH="$T/fake:/usr/bin:/bin" HOME="$T" HARNESS="$H" HARNESS_ENV_DIR="$H/env" PAT_MODE="$mode" \
    bash "$H/bin/fly-envbundle.sh" proj "$T/out-$tag" "$@" >"$T/cap/eb-$tag.out" 2>"$T/cap/eb-$tag.err"
  RC=$?
}

# ── A1: armed, --pool, no PAT → rc 0, WARN, no GH_TOKEN line ───────────────
arm; run_eb none a1 --pool
[ "$RC" = 0 ] && ok || bad "A1: armed --pool with no PAT must build (rc $RC: $(cat "$T/cap/eb-a1.err"))"
grep -q '^CLAUDE_CODE_OAUTH_TOKEN=' "$T/out-a1/global.env" 2>/dev/null && ok || bad "A1: the bundle keeps CLAUDE_CODE_OAUTH_TOKEN"
grep -q '^GH_TOKEN=' "$T/out-a1/global.env" 2>/dev/null && bad "A1: a GH_TOKEN line appeared from nowhere" || ok
grep -q 'WARN: bundle has no GH_TOKEN' "$T/cap/eb-a1.err" && ok || bad "A1: stderr must carry the WARN, got: $(cat "$T/cap/eb-a1.err")"
grep -q 'env/gh-pat' "$T/cap/eb-a1.err" && ok || bad "A1: the WARN must name env/gh-pat (what fly-dispatch still needs)"

# ── the swap block lifted from bin/fly-pool.sh by its markers ───────────────
BLOCK=$(sed -n '/^ *# >>> pool gh credential swap/,/^ *# <<< pool gh credential swap/p' "$DIR/bin/fly-pool.sh")
[ -n "$BLOCK" ] && ok || bad "swap block markers '# >>> pool gh credential swap' / '# <<< …' not found in bin/fly-pool.sh"
cat > "$T/swap.sh" <<EOF
set -uo pipefail
HARNESS="$H"
. "\$HARNESS/bin/lib/gh-app-auth.sh"
say() { echo "fly-pool: \$*" >> "$T/pool.log"; }
destroy_machine() { printf '%s\n' "\$*" >> "$T/destroy.calls"; }
pool_unclaim() { printf '%s\n' "\$*" >> "$T/unclaim.calls"; }
# BH-4859: the no-credential exits give the spawn-cap slot back, because no
# build reached the machine. SPAWNCAPTS is what spawn_one recorded before the block.
pool_spawn_cap_unrecord() { printf '%s\n' "\$*" >> "$T/unrecord.calls"; }
SPAWNCAPTS=1700000000
pool_gh_answered() { echo hub; }
pool_gh_token() {
  case " \$* " in
    *" --installation-id "*) [ -n "\${MINT:-}" ] && echo 4242 ;;
    *" --expires-at "*) [ -n "\${MINT:-}" ] && echo 2026-10-06T09:00:00Z ;;
    *) [ -n "\${MINT:-}" ] && echo "\$MINT" ;;
  esac
}
MID=mach1 KEY=BH-1 P=proj TMP="\$1" POOL_GH_TOKEN_MIN_LIFE=3300
f() {
$BLOCK
}
f; echo "RC=\$?"
EOF
# run_swap <bundle dir> <mint answer or empty> -> SRC
run_swap() {
  : > "$T/pool.log"; : > "$T/destroy.calls"; : > "$T/unclaim.calls"; : > "$T/unrecord.calls"
  SRC=$(env -i PATH="/usr/bin:/bin" HOME="$T" MINT="$2" bash "$T/swap.sh" "$1" 2>"$T/cap/swap.err" | sed -n 's/^RC=//p')
}

# ── A2: the App token fills the PAT-less bundle ─────────────────────────────
run_swap "$T/out-a1" ghs_poolfixture
[ "$SRC" = 0 ] && ok || bad "A2: swap block rc must be 0, got '$SRC' ($(cat "$T/cap/swap.err"))"
[ "$(grep -c '^GH_TOKEN=' "$T/out-a1/global.env" 2>/dev/null)" = 1 ] && grep -qx 'GH_TOKEN=ghs_poolfixture' "$T/out-a1/global.env" && ok \
  || bad "A2: the bundle must carry exactly one GH_TOKEN=<App token>"
[ "$(cat "$T/out-a1/gh-token" 2>/dev/null)" = ghs_poolfixture ] && ok || bad "A2: \$TMP/gh-token must hold the App token for rotation"
[ ! -s "$T/destroy.calls" ] && [ ! -s "$T/unclaim.calls" ] && ok || bad "A2: nothing may be destroyed or unclaimed"
[ ! -s "$T/unrecord.calls" ] && ok || bad "A2: a shipped machine keeps its spawn-cap slot, got: $(cat "$T/unrecord.calls")"

# ── C: armed, no PAT, the mint fails too → refuse the spawn ─────────────────
run_eb none c --pool
run_swap "$T/out-c" ""
[ "$SRC" = 1 ] && ok || bad "C: the swap block must return 1 when no credential is left, got '$SRC'"
# BH-7215: the swap runs before `fly machine run`, so there is no machine to
# destroy: the exit spawns nothing and says so.
[ ! -s "$T/destroy.calls" ] && ok || bad "C: the swap runs before the launch, so nothing may be destroyed, got: $(cat "$T/destroy.calls")"
grep -q 'no machine spawned, job stays queued' "$T/pool.log" && ok || bad "C: the log must say no machine spawned, got: $(cat "$T/pool.log")"
[ "$(grep -c 'no GitHub credential' "$T/unclaim.calls")" = 1 ] && ok || bad "C: pool_unclaim once with 'no GitHub credential', got: $(cat "$T/unclaim.calls")"
grep -q 'carries no PAT' "$T/pool.log" && ok || bad "C: the log must say the bundle carries no PAT, got: $(cat "$T/pool.log")"
[ "$(cat "$T/unrecord.calls")" = "BH-1 1700000000" ] && ok \
  || bad "C: the no-credential exit must give back the spawn-cap slot once (BH-4859), got: $(cat "$T/unrecord.calls")"

# ── C2: the mint fails but the bundle has a PAT → ship it (today) ───────────
run_eb pat c2 --pool
grep -qx 'GH_TOKEN=ghp_boxpatfixture' "$T/out-c2/global.env" 2>/dev/null && ok || bad "C2: with a PAT the --pool bundle carries it"
grep -q 'WARN' "$T/cap/eb-c2.err" && bad "C2: no WARN when the PAT is there" || ok
run_swap "$T/out-c2" ""
[ "$SRC" = 0 ] && ok || bad "C2: rc 0 when the PAT ships, got '$SRC'"
[ ! -s "$T/destroy.calls" ] && ok || bad "C2: nothing destroyed when the PAT ships"
[ ! -s "$T/unrecord.calls" ] && ok || bad "C2: a shipped machine keeps its spawn-cap slot, got: $(cat "$T/unrecord.calls")"
grep -q 'shipping the PAT' "$T/pool.log" && ok || bad "C2: 'shipping the PAT' logged as today"

# ── B: no third arg (fly-dispatch) with no PAT still dies, armed or not ────
for st in armed unarmed; do
  [ "$st" = armed ] && arm || unarm
  run_eb none "b-$st"
  [ "$RC" != 0 ] && ok || bad "B/$st: a dispatch bundle with no PAT must die"
  grep -q 'bundle missing GH_TOKEN' "$T/cap/eb-b-$st.err" && grep -q 'gh-token.sh --pat example-org/proj-repo printed nothing' "$T/cap/eb-b-$st.err" && ok \
    || bad "B/$st: the die names gh-token.sh and the repo, got: $(cat "$T/cap/eb-b-$st.err")"
done

# ── D: unarmed --pool with no PAT still dies ────────────────────────────────
unarm; run_eb none d --pool
[ "$RC" != 0 ] && ok || bad "D: unarmed --pool with no PAT must die"
grep -q 'not armed for App tokens' "$T/cap/eb-d.err" && ok || bad "D: the die says the hub is not armed, got: $(cat "$T/cap/eb-d.err")"

# ── D2: a junk third arg is a usage die and writes nothing ──────────────────
arm; run_eb pat d2 --poool
[ "$RC" != 0 ] && ok || bad "D2: --poool must be refused"
grep -q 'usage' "$T/cap/eb-d2.err" && ok || bad "D2: the refusal is a usage line, got: $(cat "$T/cap/eb-d2.err")"
[ ! -e "$T/out-d2/global.env" ] && ok || bad "D2: no bundle file may be written on a usage die"

# ── E: ensure-box-gh-app-default.sh step 5 ──────────────────────────────────
# run_en <tag> -> RC; captures stdout/stderr; logout and alert calls reset per run
run_en() {
  local tag="$1"
  : > "$T/logout.calls"; : > "$T/alerts.calls"
  env -i PATH="$T/fake:/usr/bin:/bin" HOME="$T" HARNESS="$H" HARNESS_ENV_DIR="$H/env" \
    FAKE_GH_STATUS="${FAKE_GH_STATUS:-0}" GH_TOKEN=ghs_processfixture \
    GH_DEFAULT_PROFILE_SNIPPET="$T/snip.sh" GH_DEFAULT_BASHRC="$T/bashrc" \
    bash "$H/bin/ensure-box-gh-app-default.sh" example-org/proj-repo >"$T/cap/en-$tag.out" 2>"$T/cap/en-$tag.err"
  RC=$?
  cp "$T/alerts.calls" "$T/cap/en-$tag.alerts"
}
refused() { # refused <case>
  [ "$RC" = 3 ] && ok || bad "$1: rc must be 3 (installed, logout deferred), got $RC ($(cat "$T/cap/en-$1.err"))"
  [ ! -s "$T/logout.calls" ] && ok || bad "$1: the keyring must NOT be logged out"
  grep -q 'logout SKIPPED' "$T/cap/en-$1.out" && ok || bad "$1: stdout must say 'logout SKIPPED'"
  [ "$(grep -c -- '--id gh-keyring-only-pat' "$T/alerts.calls")" = 1 ] && grep -q 'gh-pat' "$T/alerts.calls" && ok \
    || bad "$1: exactly one --id gh-keyring-only-pat alert naming env/gh-pat, got: $(cat "$T/alerts.calls")"
  grep -q -- '--resolve' "$T/alerts.calls" && bad "$1: no resolve while refused" || ok
}
arm; rm -f "$H/env/gh-pat" "$H/env/github-admin.env" "$T/.gitconfig" "$T/snip.sh"; base_global

# E1: no GH_TOKEN in global.env, no env/gh-pat → refused, snippet + helper still in
run_en e1; refused e1
grep -q 'credential.https://github.com.helper\|helper = ' "$T/.gitconfig" 2>/dev/null && ok || bad "E1: the git credential helper is still installed"
[ -s "$T/snip.sh" ] && ok || bad "E1: the profile snippet is still written"

# E2: env/gh-pat appears → the re-run logs out and resolves
printf '# the box PAT\nGH_PAT=ghp_filefixture\n' > "$H/env/gh-pat"
run_en e2
[ "$RC" = 0 ] && ok || bad "E2: rc 0 once env/gh-pat exists, got $RC ($(cat "$T/cap/en-e2.err"))"
[ "$(wc -l < "$T/logout.calls")" = 1 ] && ok || bad "E2: logout must run exactly once"
[ "$(grep -c -- '--resolve --id gh-keyring-only-pat' "$T/alerts.calls")" = 1 ] && ok || bad "E2: one --resolve --id gh-keyring-only-pat call, got: $(cat "$T/alerts.calls")"
rm -f "$H/env/gh-pat"

# E2b: env/gh-pat with only comments and blanks does not count
printf '# nothing here\n\n' > "$H/env/gh-pat"
run_en e2b; refused e2b
rm -f "$H/env/gh-pat"

# E3: global.env's GH_TOKEN is an App token, not a PAT → refused
base_global; printf 'GH_TOKEN=ghs_notapatfixture\n' >> "$H/env/global.env"
run_en e3; refused e3

# E4: global.env's GH_TOKEN is the admin PAT → refused
base_global; printf 'GH_TOKEN=ghp_adminfixture\n' >> "$H/env/global.env"
printf 'GH_ADMIN_TOKEN=ghp_adminfixture\n' > "$H/env/github-admin.env"
run_en e4; refused e4
rm -f "$H/env/github-admin.env"

# E5: global.env carries a real PAT → logout proceeds
base_global; printf 'export GH_TOKEN="ghp_envfixture"\n' >> "$H/env/global.env"
run_en e5
[ "$RC" = 0 ] && ok || bad "E5: rc 0 with a PAT in global.env, got $RC"
[ "$(wc -l < "$T/logout.calls")" = 1 ] && ok || bad "E5: logout must run"
grep -q -- '--id gh-keyring-only-pat' "$T/alerts.calls" && ! grep -q -- '--resolve' "$T/alerts.calls" && bad "E5: no refusal alert" || ok
base_global

# E6: no keyring login at all → today's message, rc 0, no alert
FAKE_GH_STATUS=1 run_en e6
[ "$RC" = 0 ] && ok || bad "E6: rc 0 with nothing to log out, got $RC"
grep -q 'nothing to log out' "$T/cap/en-e6.out" && ok || bad "E6: says 'nothing to log out'"
[ ! -s "$T/alerts.calls" ] && ok || bad "E6: no alert call, got: $(cat "$T/alerts.calls")"
[ ! -s "$T/logout.calls" ] && ok || bad "E6: no logout call"

# ── G: the pool call sites pass --pool and fly-dispatch does not ────────────
# A source pin, on purpose: every fly-pool fixture stubs the bundler, so this is
# what fails when a call site loses the flag. Each grep must match exactly once.
[ "$(grep -c 'fly-envbundle.sh" "\$P" "\$TMP" --pool >/dev/null 2>>"\$LOG"' "$DIR/bin/fly-pool.sh")" = 1 ] && ok \
  || bad "G: bin/fly-pool.sh spawn must call fly-envbundle.sh with --pool, stderr to \$LOG"
[ "$(grep -c 'fly-envbundle.sh" "\$P" "\$TMP" --pool 2>&1' "$DIR/bin/fly-pool-rollout.sh")" = 1 ] && ok \
  || bad "G: bin/fly-pool-rollout.sh smoke must call fly-envbundle.sh with --pool"
DISP=$(grep 'fly-envbundle.sh' "$DIR/bin/fly-dispatch.sh" | grep -v '^ *#')
[ -n "$DISP" ] && ! grep -q -- '--pool' <<<"$DISP" && ok \
  || bad "G: bin/fly-dispatch.sh must call fly-envbundle.sh WITHOUT --pool (it ships the PAT as-is), got: $DISP"

# ── F: no fixture token value leaks anywhere we captured ────────────────────
LEAK=$(grep -rlE 'ghp_[a-z]*fixture|ghs_[a-z]*fixture' "$T/cap" "$T/pool.log" "$H/logs" 2>/dev/null)
[ -z "$LEAK" ] && ok || bad "F: a fixture token value reached: $LEAK"

echo "fly-envbundle-pool-nopat (BH-4798): $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
