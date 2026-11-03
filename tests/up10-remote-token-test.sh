#!/bin/bash
# tests/up10-remote-token-test.sh — BH-639: the up10 ssh hop mints its GitHub
# token and sets its PATH ON THE FAR SIDE, and the token never crosses the wire.
#
# WHY. `ssh -o BatchMode=yes` carries no GH_TOKEN and no harness env. Until
# 2026-09-17 the hop's remote command string was
#   mkdir -p /root/harness/tmp && cat > <brief> && up10-lane.sh --here <slug> …
# so the far side's dedupe read (`gh issue list`, bin/up10-lane.sh:88) ran with
# no credential at all, the fail-closed check at :91 fired with "refusing to
# file a duplicate on a read that did not answer", and every orchestrator-turn
# up10 launch died there. The far-side check is right; the hub-side string was
# the defect.
#
# WHY DRIVEN AND NOT GREPPED. A regex over the ssh line would go green on a
# string that mints a token the far side never receives. So this suite RUNS the
# real bin/up10-lane.sh with a fakessh that EXECUTES the remote command it is
# handed, under `env -i` with a stripped PATH — the far side's environment,
# reproduced — and reads back what the far side's `gh` actually ran on.
#
# Nothing here opens a socket, touches a real box, or files a real issue.
# ghs_FAKE_TOKEN_9f3a is a fixture string, not a credential.
#
#   bash tests/up10-remote-token-test.sh     exit 0 = all pass
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
if [ -r "$(dirname "$0")/lib/scratch.sh" ]; then
  . "$(dirname "$0")/lib/scratch.sh" || exit 1
else
  # Until #609 lands tests/lib/scratch.sh on main (see #629) this branch owns
  # $T on the same contract the lib gives: a private tree under TMPDIR, removed
  # on exit. When the lib arrives it takes over and these lines go unused.
  T=$(mktemp -d "${TMPDIR:-/tmp}/up10-remote-token.XXXXXX") || exit 1
  trap 'rm -rf "$T"' EXIT
fi
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

UP10="$DIR/bin/up10-lane.sh"
[ -r "$UP10" ] && ok || bad "bin/up10-lane.sh is missing — there is no hop to test"

TOKEN=ghs_FAKE_TOKEN_9f3a   # fixture value. Never a real credential (D26).
HUB="$T/hub"; REM="$T/remote"
mkdir -p "$HUB/bin" "$HUB/logs" "$HUB/state" "$T/fakebin" \
         "$REM/bin" "$REM/logs" "$REM/state" "$REM/tmp"
printf 'box-hub\n'          > "$HUB/state/box-name"
printf 'box-small\n'      > "$REM/state/box-name"
printf '10.0.0.13\n'               > "$T/stub-tailnet-ip"
printf 'example-org/cromford\n'  > "$T/stub-hub-repo"
printf '%s\n' "$TOKEN"              > "$T/stub-mint"
printf 'do the thing\n'             > "$T/brief.txt"

# ── the fleet registry, answered from files this suite rewrites ──────────────
cat > "$HUB/bin/box-for.sh" <<EOF
#!/bin/bash
echo box-small
EOF
cat > "$HUB/bin/fleet-conf.sh" <<EOF
#!/bin/bash
case "\${1:-}" in
  --tailnet-ip-of-box) cat "$T/stub-tailnet-ip" ;;
  *) case "\${2:-}" in repo) cat "$T/stub-hub-repo" ;; esac ;;
esac
EOF
cat > "$REM/bin/fleet-conf.sh" <<EOF
#!/bin/bash
case "\${2:-}" in repo) echo example-org/cromford ;; esac
EOF

# gh-token.sh on BOTH trees: records which box asked and for what, then prints
# whatever the fixture currently mints (empty = a mint that answered nothing).
for H in "$HUB" "$REM"; do
  cat > "$H/bin/gh-token.sh" <<EOF
#!/bin/bash
printf '%s %s\n' "\$(cat "\$(dirname "\$0")/../state/box-name")" "\$*" >> "$T/mint-argv.txt"
cat "$T/stub-mint"
EOF
done
chmod +x "$HUB"/bin/*.sh "$REM"/bin/*.sh

# The far side's harness: a COPY of the real script, plus a run-build.sh that
# records its argv and unblocks the reader on a fifo (a detached `setsid … &`
# launch is otherwise a race the test would have to guess a duration for).
cp "$UP10" "$REM/bin/up10-lane.sh"; chmod +x "$REM/bin/up10-lane.sh"
mkdir -p "$REM/bin/lib" && cp "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$DIR/bin/lib/gh-rest-list.sh" "$REM/bin/lib/"   # TEST-CHANGE BH-1651
# scratch-closure-allow: BH-4080 the lane under test runs under env -i or in its own harness root, so HARNESS_DEPLOYMENT_FILE does not reach it and bin/lib/deployment.sh must sit beside its copied libs
cp "$DIR/bin/lib/deployment.sh" "$REM/bin/lib/"  # BH-4080: up10-lane.sh sources it (the far side runs under env -i)
scratch_install_closure bin/lib/tracker/gh-issue-create.sh "$REM" >/dev/null || exit 1  # BH-8962: up10 files its ticket over REST
mkfifo "$T/rb.fifo"
cat > "$REM/bin/run-build.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/rb-argv.txt"
echo launched > "$T/rb.fifo"
EOF
chmod +x "$REM/bin/run-build.sh"

# gh: records the token it was handed and the PATH it was found on, refuses
# when no credential reached it (rc 1, exactly what the far side saw), answers
# otherwise.
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf 'GH_TOKEN=%s :: %s\n' "\${GH_TOKEN:-<unset>}" "\$*" >> "$T/gh-argv.txt"
printf '%s\n' "\${PATH:-<unset>}" >> "$T/gh-path.txt"
[ -n "\${GH_TOKEN:-}" ] || { echo "gh: authentication required" >&2; exit 1; }
. "$DIR/tests/lib/gh-cli-rest-adapter.sh" || exit 1  # BH-8962: the REST create, from the arm below
gh_cli_rest_create "\$0" "\$@" && exit 0
case "\${1:-} \${2:-}" in
  "api -i")       printf 'HTTP/2 200\r\n\r\n[]' ;;   # TEST-CHANGE BH-1651: the dedupe list is REST
  "issue create") echo "https://github.com/example-org/cromford/issues/42" ;;
esac
EOF
# ssh: records the exact argv the hub passed, then EXECUTES the remote command
# string against the scratch "remote" tree under a stripped environment — no
# GH_TOKEN, no HARNESS the hub set, and a PATH without /usr/local/bin.
cat > "$T/fakebin/fakessh" <<EOF
#!/bin/bash
printf '%s\n' "\$@" > "$T/ssh-argv.txt"
cmd=\$(printf '%s' "\${@: -1}" | sed "s#/root/harness#$REM#g")
exec env -i HOME=/root HARNESS="$REM" PATH="$T/fakebin:/usr/bin:/bin" bash -c "\$cmd"
EOF
chmod +x "$T/fakebin/gh" "$T/fakebin/fakessh"

run_hop() { # run_hop <args...> ; echoes rc, stdout in $T/up10.out
  rm -f "$T/ssh-argv.txt" "$T/gh-argv.txt" "$T/gh-path.txt" \
        "$T/rb-argv.txt" "$T/mint-argv.txt" "$REM/tmp/up10-demo-slug.brief"
  : > "$HUB/logs/ALERTS.log"; : > "$HUB/logs/up10.log"; : > "$REM/logs/ALERTS.log"
  ( export HARNESS="$HUB" PATH="$T/fakebin:$PATH" UP10_SSH="$T/fakebin/fakessh"
    env -u GH_TOKEN bash "$UP10" "$@" > "$T/up10.out" 2>"$T/up10.err" )
  echo $?
}

# ═══ launch (R1, R4): the hop reaches LAUNCHED with no hand-exported token ═══
RC=$(run_hop demo-slug "$T/brief.txt")
[ "$RC" = 0 ] \
  && ok || bad "the hop exited $RC, not 0: $(tail -2 "$T/up10.err")"
grep -q '^LAUNCHED BH-42' "$T/up10.out" \
  && ok || bad "the hop did not reach LAUNCHED BH-42: $(cat "$T/up10.out")"
IFS= read -r -t 20 _ <> "$T/rb.fifo" \
  && ok || bad "run-build.sh never launched on the far side: $(tail -2 "$T/up10.err")"
[ "$(cat "$T/rb-argv.txt" 2>/dev/null)" = "cromford 42 BH-42" ] \
  && ok || bad "run-build.sh got the wrong argv: $(cat "$T/rb-argv.txt" 2>/dev/null)"
[ "$(cat "$REM/tmp/up10-demo-slug.brief" 2>/dev/null)" = "$(cat "$T/brief.txt")" ] \
  && ok || bad "the brief did not arrive intact on the far side"

# ═══ mint (R1): exactly one mint, on the FAR side, for the fleet.conf repo ═══
MINTS=$(grep -c . "$T/mint-argv.txt" 2>/dev/null); MINTS=${MINTS:-0}
[ "$MINTS" = 1 ] \
  && ok || bad "expected exactly one token mint, got $MINTS: $(cat "$T/mint-argv.txt" 2>/dev/null)"
[ "$(head -1 "$T/mint-argv.txt" 2>/dev/null)" = "box-small example-org/cromford" ] \
  && ok || bad "the mint did not happen on the far side for the fleet.conf repo: $(cat "$T/mint-argv.txt" 2>/dev/null)"
case "$(head -1 "$T/gh-argv.txt" 2>/dev/null)" in
  "GH_TOKEN=$TOKEN :: api -i -X GET repos/example-org/cromford/issues"*) ok ;;   # TEST-CHANGE BH-1651
  *) bad "the far side's first gh call did not run on the minted token: $(head -1 "$T/gh-argv.txt" 2>/dev/null)" ;;
esac

# ═══ PATH (R2): extended, not replaced ═══════════════════════════════════════
RPATH=$(head -1 "$T/gh-path.txt" 2>/dev/null)
case "$RPATH" in
  *:/usr/local/bin:*|*:/usr/local/bin) ok ;;
  *) bad "the far side's PATH has no /usr/local/bin: $RPATH" ;;
esac
case "$RPATH" in
  "$T/fakebin:"*) ok ;;
  *) bad "the far side's PATH was replaced, not extended — what sshd handed the session is gone: $RPATH" ;;
esac

# ═══ never over the wire (R3) ════════════════════════════════════════════════
grep -qF "$TOKEN" "$T/ssh-argv.txt" 2>/dev/null \
  && bad "the token VALUE is in the ssh argv — it would land in ps on both sides" || ok
grep -q '^box-hub ' "$T/mint-argv.txt" 2>/dev/null \
  && bad "the HUB minted a token for the hop: $(cat "$T/mint-argv.txt")" || ok
grep -qF "$TOKEN" "$HUB/logs/up10.log" 2>/dev/null \
  && bad "the token value was written to logs/up10.log" || ok
grep -qF 'gh-token.sh example-org/cromford' "$T/ssh-argv.txt" 2>/dev/null \
  && ok || bad "the remote command string does not mint a token on the far side: $(tr '\n' ' ' < "$T/ssh-argv.txt" 2>/dev/null)"

# ═══ fail-closed (R5): a mint that answers nothing still stops the lane ══════
: > "$T/stub-mint"
RC=$(run_hop demo-slug "$T/brief.txt")
[ "$RC" = 2 ] \
  && ok || bad "a far side that cannot read exited $RC, not the fail-closed 2"
grep -q 'LAUNCHED' "$T/up10.out" \
  && bad "a failed far-side read still reported a launch: $(cat "$T/up10.out")" || ok
[ -s "$T/rb-argv.txt" ] \
  && bad "a failed far-side read still launched a build" || ok
grep -q 'gh issue list failed' "$REM/logs/ALERTS.log" \
  && ok || bad "the far side stopped without saying so in ALERTS.log: $(cat "$REM/logs/ALERTS.log")"
printf '%s\n' "$TOKEN" > "$T/stub-mint"

# ═══ no repo (fail closed on the hub, before the hop) ════════════════════════
: > "$T/stub-hub-repo"
RC=$(run_hop demo-slug "$T/brief.txt")
[ "$RC" = 2 ] \
  && ok || bad "a hub with no repo in fleet.conf exited $RC, not the fail-closed 2"
[ -e "$T/ssh-argv.txt" ] \
  && bad "the hub hopped anyway, with a remote command that cannot mint a token" || ok
grep -q 'fleet.conf has no repo' "$HUB/logs/ALERTS.log" \
  && ok || bad "the hub stopped without naming why: $(cat "$HUB/logs/ALERTS.log")"
printf 'example-org/cromford\n' > "$T/stub-hub-repo"

echo "up10-remote-token-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
