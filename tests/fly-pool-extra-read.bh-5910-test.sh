#!/bin/bash
# tests/fly-pool-extra-read.bh-5910-test.sh — BH-5910: bin/fly-pool.sh ships a
# read-only token for the project's extra repos to the pool machine.
#
# The knob is lane.fly-pool.<project>.extra_read_repos (env EXTRA_READ_REPOS,
# catalog/lanes.d/fly-pool.json). With it set, the spawn swap asks
# bin/gh-token.sh --extra-read for a second token, writes GH_EXTRA_READ_TOKEN and
# GH_EXTRA_READ_REPOS into the bundle's global.env, and pushes the token to
# /run/harness-env/gh-token-read, where fly/gh-credential.sh answers it for
# those repos only.
#
# PINNED (the REAL swap block, lifted from bin/fly-pool.sh by its markers):
#   1 empty knob: no --extra-read call, no GH_EXTRA_READ_* line, no read mput.
#   2 knob set: both lines in global.env, the read token left in
#     $TMP/gh-token-read for the push phase (BH-7215), the project token
#     untouched, and the token value never in the say output.
#   3 a missing repo on stderr: said, and ONE ALERTS call per project/repo/day.
#   4 no read token: the machine still ships with the project token.
#   5 the project mint answered the PAT (no expiry): no --extra-read call.
#   6 the block pushes nothing (BH-7215; the failed-push case is in
#     tests/fly-pool-warmup.bh-7215-test.sh L3).
#   7 gh_token_live_sync_env (the rotation's global.env rewrite) keeps the
#     GH_EXTRA_READ_TOKEN line.
#   8 a space-separated knob (the documented form) ships as one comma list,
#     the project slug and a duplicate dropped, and survives `. global.env`.
#   9 a `$(...)` word or a newline KEY= line in the knob never reaches
#     global.env, and sourcing the shipped file runs nothing.
# Run from anywhere: bash tests/fly-pool-extra-read.bh-5910-test.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

H="$T/h"
mkdir -p "$H/bin/lib" "$H/env" "$H/flags" "$H/logs"
scratch_install_closure bin/lib/gh-app-auth.sh "$H" >/dev/null || { echo "closure install failed for bin/lib/gh-app-auth.sh"; exit 1; }
: > "$H/env/github-app.env"
printf '#!/bin/bash\nexit 0\n' > "$H/bin/gh-token.sh"
cat > "$H/bin/alert-line.sh" <<STUB
#!/bin/bash
printf '%s\n' "\$*" >> "$T/alerts.calls"
STUB
chmod +x "$H/bin/"*.sh

BLOCK=$(sed -n '/^ *# >>> pool gh credential swap/,/^ *# <<< pool gh credential swap/p' "$DIR/bin/fly-pool.sh")
[ -n "$BLOCK" ] && ok || bad "swap block markers not found in bin/fly-pool.sh"
cat > "$T/swap.sh" <<EOF
set -uo pipefail
HARNESS="$H"
. "\$HARNESS/bin/lib/gh-app-auth.sh"
say() { echo "fly-pool: \$*" >> "$T/pool.log"; }
destroy_machine() { printf '%s\n' "\$*" >> "$T/destroy.calls"; }
pool_unclaim() { printf '%s\n' "\$*" >> "$T/unclaim.calls"; }
pool_spawn_cap_unrecord() { :; }
mput() { printf '%s %s\n' "\$1" "\$3" >> "$T/mput.calls"; cp "\$2" "$T/mput-\$(basename "\$3")"; [ "\${MPUT_FAILS:-0}" != 1 ]; }
pool_gh_answered() { echo builders; }
pool_gh_token() {
  printf '%s\n' "\$*" >> "$T/token.calls"
  case " \$* " in
    *" --extra-read "*) [ -n "\${XERR:-}" ] && printf '%s\n' "\$XERR" >&2
                        [ -n "\${XMINT:-}" ] && echo "\$XMINT"; return 0 ;;
    *" --installation-id "*) echo 4242 ;;
    *" --expires-at "*) [ -n "\${MEXPIRY:-}" ] && echo "\$MEXPIRY" ;;
    *) echo tok-fixture-project ;;
  esac
}
MID=mach1 KEY=BH-1 P=proj TMP="\$1" POOL_GH_TOKEN_MIN_LIFE=3300
f() {
$BLOCK
}
f; echo "RC=\$?"
EOF
# run_swap [VAR=value ...] -> SRC; bundle in $T/b
run_swap() {
  rm -rf "$T/b" "$T"/mput-*; mkdir -p "$T/b"
  printf 'CLAUDE_CODE_OAUTH_TOKEN=oauth-fixture\nGH_TOKEN=ghp_patfixture\nGH_EXTRA_READ_TOKEN=tok-fixture-stale\n' > "$T/b/global.env"
  printf 'REPO_SLUG=example-org/proj-repo\n' > "$T/b/proj.env"
  : > "$T/pool.log"; : > "$T/token.calls"; : > "$T/mput.calls"
  SRC=$(env -i PATH="/usr/bin:/bin" HOME="$T" MEXPIRY=2026-10-10T15:00:00Z "$@" bash "$T/swap.sh" "$T/b" 2>"$T/swap.err" | sed -n 's/^RC=//p')
}

# ── 1. empty knob: today's bytes ────────────────────────────────────────────
run_swap EXTRA_READ_REPOS=
[ "$SRC" = 0 ] && ok || bad "1: rc must be 0, got '$SRC' ($(cat "$T/swap.err"))"
grep -q -- '--extra-read' "$T/token.calls" && bad "1: an empty knob must make no --extra-read call" || ok
grep -q '^GH_EXTRA_READ_REPOS=' "$T/b/global.env" && bad "1: an empty knob must write no GH_EXTRA_READ_REPOS line" || ok
[ ! -e "$T/b/gh-token-read" ] && ok || bad "1: an empty knob must write no gh-token-read file"
grep -q 'gh-token-read' "$T/mput.calls" && bad "1: an empty knob must push no gh-token-read" || ok
grep -qx 'GH_TOKEN=tok-fixture-project' "$T/b/global.env" && ok || bad "1: the project token swap must happen as today"

# ── 2. knob set: the read token reaches the machine ─────────────────────────
run_swap EXTRA_READ_REPOS="example-org/OtherRepo,example-org/ThirdRepo" XMINT=tok-fixture-read
[ "$SRC" = 0 ] && ok || bad "2: rc must be 0, got '$SRC' ($(cat "$T/swap.err"))"
grep -qx -- '--extra-read example-org/OtherRepo,example-org/ThirdRepo --min-life 3300 example-org/proj-repo' "$T/token.calls" && ok \
  || bad "2: the read mint must pass the knob, min-life and project slug, got: $(cat "$T/token.calls")"
[ "$(grep -c '^GH_EXTRA_READ_TOKEN=' "$T/b/global.env")" = 1 ] && grep -qx 'GH_EXTRA_READ_TOKEN=tok-fixture-read' "$T/b/global.env" && ok \
  || bad "2: global.env must carry exactly one GH_EXTRA_READ_TOKEN=<read token>, got: $(grep GH_EXTRA "$T/b/global.env")"
grep -qx 'GH_EXTRA_READ_REPOS=example-org/OtherRepo,example-org/ThirdRepo' "$T/b/global.env" && ok || bad "2: global.env must carry GH_EXTRA_READ_REPOS=<knob>"
grep -qx 'GH_TOKEN=tok-fixture-project' "$T/b/global.env" && ok || bad "2: GH_TOKEN must stay the project token"
# BH-7215: the swap runs before the launch, so it pushes nothing; it leaves the
# read token in $TMP/gh-token-read for spawn_one's push phase
# (tests/fly-pool-warmup.bh-7215-test.sh L3 drives that push).
[ ! -s "$T/mput.calls" ] && ok || bad "2: the swap block must push nothing (it runs before the launch), got: $(cat "$T/mput.calls")"
[ "$(cat "$T/b/gh-token-read" 2>/dev/null)" = tok-fixture-read ] && ok || bad "2: \$TMP/gh-token-read must hold the read token for the push phase"
[ "$(cat "$T/b/gh-token" 2>/dev/null)" = tok-fixture-project ] && ok || bad "2: \$TMP/gh-token must stay the project token"
grep -q 'read-only token for the extra repos of example-org/proj-repo (example-org/OtherRepo,example-org/ThirdRepo; left out: none)' "$T/pool.log" && ok || bad "2: the log must name the shipped repos and none left out, got: $(cat "$T/pool.log")"
grep -q 'tok-fixture-read' "$T/pool.log" "$T/swap.err" && bad "2: the read token value reached the log" || ok

# ── 3. missing repo: said, one ALERTS per project/repo/day ──────────────────
: > "$T/alerts.calls"
run_swap EXTRA_READ_REPOS="example-org/Gone,example-org/OtherRepo" XMINT=tok-fixture-read XERR='gh-token: EXTRA_READ_REPO_MISSING example-org/Gone'
grep -q 'EXTRA_READ_REPO_MISSING example-org/Gone' "$T/pool.log" && ok || bad "3: the missing line must be said, got: $(cat "$T/pool.log")"
[ "$(grep -c 'example-org/Gone' "$T/alerts.calls")" = 1 ] && grep -q 'extra_read_repos' "$T/alerts.calls" && ok \
  || bad "3: one ALERTS call naming the repo and the setting, got: $(cat "$T/alerts.calls")"
grep -q 'left out: example-org/Gone)' "$T/pool.log" && ok || bad "3: the shipped line must name the repo left out, got: $(cat "$T/pool.log")"
grep -qx 'GH_EXTRA_READ_REPOS=example-org/OtherRepo' "$T/b/global.env" && ok || bad "3: GH_EXTRA_READ_REPOS must drop the missing repo, got: $(grep GH_EXTRA_READ_REPOS "$T/b/global.env")"
ls "$H/flags" | grep -q '^alerted-extra-read-missing-proj-example-org-Gone-[0-9]\{8\}$' && ok || bad "3: the day flag must exist, got: $(ls "$H/flags")"
run_swap EXTRA_READ_REPOS="example-org/Gone,example-org/OtherRepo" XMINT=tok-fixture-read XERR='gh-token: EXTRA_READ_REPO_MISSING example-org/Gone'
[ "$(grep -c 'example-org/Gone' "$T/alerts.calls")" = 1 ] && ok || bad "3: a second spawn the same day must not page again, got: $(cat "$T/alerts.calls")"

# ── 4. no read token: the machine still ships with the project token ────────
run_swap EXTRA_READ_REPOS="example-org/OtherRepo"
[ "$SRC" = 0 ] && ok || bad "4: rc must be 0 without a read token, got '$SRC'"
[ ! -s "$T/destroy.calls" ] 2>/dev/null && ok || bad "4: nothing may be destroyed"
grep -qx 'GH_TOKEN=tok-fixture-project' "$T/b/global.env" && ok || bad "4: the project token must still ship"
grep -q '^GH_EXTRA_READ_' "$T/b/global.env" && bad "4: no GH_EXTRA_READ_* line (the stale one removed) without a read token" || ok
[ ! -e "$T/b/gh-token-read" ] && ! grep -q 'gh-token-read' "$T/mput.calls" && ok || bad "4: no read file, no read mput"
grep -q 'no read-only token' "$T/pool.log" && ok || bad "4: the log must say there is no read token, got: $(cat "$T/pool.log")"

# ── 5. the project answer has no expiry (PAT path): no read mint ────────────
run_swap EXTRA_READ_REPOS="example-org/OtherRepo" XMINT=tok-fixture-read MEXPIRY=
grep -q -- '--extra-read' "$T/token.calls" && bad "5: no expiry means no App mint, so no --extra-read call" || ok

# ── 6. the read push left the block (BH-7215) ───────────────────────────────
# A failed read push is said and the spawn goes ahead: that push is now in
# spawn_one's push phase, driven in tests/fly-pool-warmup.bh-7215-test.sh L3.
# Here: with a push that would fail, the block still answers 0 and pushes nothing.
run_swap EXTRA_READ_REPOS="example-org/OtherRepo" XMINT=tok-fixture-read MPUT_FAILS=1
[ "$SRC" = 0 ] && ok || bad "6: the swap block must answer 0, got '$SRC'"
grep -q 'gh-token-read' "$T/mput.calls" && bad "6: the swap block must not push gh-token-read, got: $(cat "$T/mput.calls")" || ok

# ── 7. the rotation's global.env rewrite keeps the read line ────────────────
mkdir -p "$T/menv"
printf 'GH_TOKEN=tok-fixture-old\nGH_EXTRA_READ_TOKEN=tok-fixture-read\nGH_EXTRA_READ_REPOS=example-org/OtherRepo\n' > "$T/menv/global.env"
printf 'tok-fixture-new\n' > "$T/menv/gh-token"
env -i PATH="/usr/bin:/bin" HARNESS="$H" GH_TOKEN_LIVE_FILE="$T/menv/gh-token" bash -c \
  ". '$DIR/bin/lib/gh-token-live.sh' && gh_token_live_sync_env '$T/menv/global.env'" >/dev/null 2>&1
grep -qx 'GH_TOKEN=tok-fixture-new' "$T/menv/global.env" && ok || bad "7: the sync must rewrite GH_TOKEN (fixture check), got: $(cat "$T/menv/global.env")"
grep -qx 'GH_EXTRA_READ_TOKEN=tok-fixture-read' "$T/menv/global.env" && ok || bad "7: the sync must keep GH_EXTRA_READ_TOKEN"

# load_env <global.env> -> the GH_EXTRA_READ_REPOS the builder sees after its
# `set -a; . global.env` (fly/builder-runner.sh), and the load's rc.
load_env() {
  env -i PATH="/usr/bin:/bin" HOME="$T" bash -c 'set -a; . "$1"; printf "rc=%s val=[%s] gh=[%s]\n" "$?" "${GH_EXTRA_READ_REPOS:-}" "${GH_TOKEN:-}"' _ "$1" 2>&1
}

# ── 8. space-separated knob: one comma list that survives the source ────────
run_swap EXTRA_READ_REPOS="example-org/ThirdRepo example-org/OtherRepo  example-org/otherrepo example-org/proj-repo" XMINT=tok-fixture-read
[ "$SRC" = 0 ] && ok || bad "8: rc must be 0, got '$SRC' ($(cat "$T/swap.err"))"
grep -qx 'GH_EXTRA_READ_REPOS=example-org/OtherRepo,example-org/ThirdRepo' "$T/b/global.env" && ok \
  || bad "8: a space-separated knob must ship as a sorted, deduped comma list without the project, got: $(grep GH_EXTRA_READ_REPOS "$T/b/global.env")"
LOAD=$(load_env "$T/b/global.env")
[ "$LOAD" = "rc=0 val=[example-org/OtherRepo,example-org/ThirdRepo] gh=[tok-fixture-project]" ] && ok \
  || bad "8: sourcing the shipped global.env must keep GH_EXTRA_READ_REPOS, got: $LOAD"

# ── 9. shell text in the knob never reaches the builder's shell ─────────────
rm -f "$T/pwned"
run_swap EXTRA_READ_REPOS="example-org/OtherRepo,\$(touch $T/pwned),\`touch $T/pwned\`;x/y
GH_TOKEN=ghp_injected" XMINT=tok-fixture-read
[ "$SRC" = 0 ] && ok || bad "9: rc must be 0, got '$SRC' ($(cat "$T/swap.err"))"
grep -qx 'GH_EXTRA_READ_REPOS=example-org/OtherRepo' "$T/b/global.env" && ok \
  || bad "9: only the owner/repo words may ship, got: $(grep GH_EXTRA_READ_REPOS "$T/b/global.env")"
grep -q 'pwned\|injected' "$T/b/global.env" && bad "9: shell text from the knob reached global.env: $(cat "$T/b/global.env")" || ok
LOAD=$(load_env "$T/b/global.env")
[ "$LOAD" = "rc=0 val=[example-org/OtherRepo] gh=[tok-fixture-project]" ] && ok || bad "9: sourcing the shipped global.env must be clean, got: $LOAD"
[ ! -e "$T/pwned" ] && ok || bad "9: sourcing global.env ran a command from the knob"
run_swap EXTRA_READ_REPOS="\$(touch $T/pwned)" XMINT=tok-fixture-read
grep -q '^GH_EXTRA_READ_' "$T/b/global.env" && bad "9: a knob with no valid repo must ship no GH_EXTRA_READ_* line, got: $(grep GH_EXTRA "$T/b/global.env")" || ok
grep -q 'gh-token-read' "$T/mput.calls" && bad "9: a knob with no valid repo must push no read token" || ok
[ ! -e "$T/pwned" ] && ok || bad "9: the swap itself ran a command from the knob"

echo "fly-pool-extra-read (BH-5910): $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
