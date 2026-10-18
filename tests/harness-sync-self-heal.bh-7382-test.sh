#!/bin/bash
# tests/harness-sync-self-heal.bh-7382-test.sh — a failed fast-forward in the
# deploy path heals itself on a clean tree, and alerts with git's own stderr
# when it cannot (BH-7382).
#
# WHY. On project-6-os one held ref lock made `git pull --ff-only` fail. The
# deploy printed a bare `pull-failed`, context-gate refused every build, and
# nothing said why or fixed it on the next tick. The checkout was clean and
# behind: a reset to the ref freshness() had just fetched was always safe.
#
#   a1  the fast-forward fails once on a clean tree: rc 0, HEAD = origin/main,
#       and update-runners.log has the `reset to origin/main` line with the
#       `cannot lock ref` text
#   a2  a tracked docs/x.md is modified and every fast-forward fails: rc 20,
#       stdout `pull-failed: fatal: cannot lock ref ...`, one ALERTS line with
#       that stderr and `tracked files modified: docs/x.md`, HEAD unchanged,
#       the edit still on disk (no data loss). docs/ is the near miss:
#       freshness() does not count it as dirty, so the run reaches this step
#   a3  the next tick after a2 (wrapper off, edit reverted): rc 0, HEAD =
#       origin/main
#   a4  an untracked bin/new.sh that origin/main adds, every fast-forward
#       fails: rc 0 after the reset, the old content is kept under
#       state/harness-sync-displaced/*/bin/new.sh
#   a5  a2 twice in the same hour: exactly 1 ALERTS line
#   a6  no failure injected: rc 0 and no `reset` line in update-runners.log
#   a7  six old stamp dirs plus this run's: the 5 newest stay
#
# The failure is a `git` wrapper first on PATH. It fails a `pull` OR a `merge`
# subcommand (the old code pulls, the new code merges the fetched ref) and
# forwards every other call to the real git. The clock is pinned with
# HARNESS_SYNC_NOW.
# Run from anywhere: tests/harness-sync-self-heal.bh-7382-test.sh   (exit 0 = all pass)
set -uo pipefail
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$(dirname "$0")/lib/scratch.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v git >/dev/null && command -v flock >/dev/null && command -v rsync >/dev/null \
  || { echo "git/flock/rsync missing — skipping"; exit 0; }

REAL_GIT=$(command -v git)
LOCKERR="fatal: cannot lock ref 'refs/heads/main': Unable to create '.git/refs/heads/main.lock': File exists"
export HARNESS_SYNC_NOW=2000000000   # 2033-05-18T03:33:20Z, one fixed hour

# ── the git wrapper ──────────────────────────────────────────────────────────
# Mode file: off | once | always. `once` fails the first pull/merge and writes
# a marker, so every later call passes.
mkdir -p "$T/wrap"
cat > "$T/wrap/git" <<EOF
#!/bin/bash
mode=\$(cat "$T/git-mode" 2>/dev/null || echo off)
sub=""; skip=0
for a in "\$@"; do
  if [ "\$skip" = 1 ]; then skip=0; continue; fi
  case "\$a" in
    -C|-c|--git-dir|--work-tree|--namespace) skip=1 ;;
    -*) ;;
    *) sub="\$a"; break ;;
  esac
done
case "\$sub" in
  pull|merge)
    fail=0
    case "\$mode" in
      always) fail=1 ;;
      once) [ -e "$T/git-once-done" ] || { : > "$T/git-once-done"; fail=1; } ;;
    esac
    if [ "\$fail" = 1 ]; then
      echo "$LOCKERR" >&2
      exit 128
    fi ;;
esac
exec "$REAL_GIT" "\$@"
EOF
chmod +x "$T/wrap/git"
gitmode() { printf '%s\n' "$1" > "$T/git-mode"; rm -f "$T/git-once-done"; }

# ── fixture: origin, a pusher clone, and a checkout behind by 2 commits ─────
# C1 edits bin/x.sh; C2 adds bin/new.sh (the a4 collision).
fixture() { # fixture <name> -> sets O (origin) CK (checkout) H (harness) LOG ALERTS
  local d="$T/$1"
  O="$d/origin"; CK="$d/ck"; H="$d/h"
  mkdir -p "$H/bin" "$H/logs" "$H/state" "$H/locks" "$H/flags" "$H/prompts" \
           "$H/fly" "$H/catalog" "$H/checks" "$H/guardrails" "$H/config" "$H/env"
  cp "$DIR/bin/alert-line.sh" "$H/bin/"
  LOG="$H/logs/update-runners.log"; ALERTS="$H/logs/ALERTS.log"
  "$REAL_GIT" init -q --bare "$O"
  "$REAL_GIT" clone -q "$O" "$d/src" 2>/dev/null
  "$REAL_GIT" -C "$d/src" config user.email t@t; "$REAL_GIT" -C "$d/src" config user.name t
  mkdir -p "$d/src/bin" "$d/src/prompts" "$d/src/catalog" "$d/src/docs"
  printf '#!/bin/bash\n:\n' > "$d/src/bin/x.sh"
  printf 'p\n' > "$d/src/prompts/p.md"
  printf '{}\n' > "$d/src/catalog/c.json"
  printf 'doc\n' > "$d/src/docs/x.md"
  printf 'fleet\n' > "$d/src/fleet.conf"
  "$REAL_GIT" -C "$d/src" add -A >/dev/null
  "$REAL_GIT" -C "$d/src" commit -qm seed
  "$REAL_GIT" -C "$d/src" branch -M main 2>/dev/null
  "$REAL_GIT" -C "$d/src" push -q origin main 2>/dev/null
  "$REAL_GIT" clone -q -b main "$O" "$CK" 2>/dev/null
  printf '#!/bin/bash\necho c1\n' > "$d/src/bin/x.sh"
  "$REAL_GIT" -C "$d/src" commit -qam c1
  printf '#!/bin/bash\necho new-from-origin\n' > "$d/src/bin/new.sh"
  "$REAL_GIT" -C "$d/src" add -A >/dev/null
  "$REAL_GIT" -C "$d/src" commit -qm c2
  "$REAL_GIT" -C "$d/src" push -q origin main 2>/dev/null
  ORIGIN_SHA=$("$REAL_GIT" -C "$d/src" rev-parse HEAD)
  START_SHA=$("$REAL_GIT" -C "$CK" rev-parse HEAD)
}

sync() {
  ( export HARNESS="$H" HARNESS_CHECKOUT="$CK" PATH="$T/wrap:$PATH"
    bash "$DIR/bin/harness-sync.sh" "$@" ) >"$T/out.txt" 2>"$T/err.txt"
  RC=$?
}
head_sha() { "$REAL_GIT" -C "$CK" rev-parse HEAD; }
nlines() { local n; n=$(grep -cF -- "$2" "$1" 2>/dev/null) || n=0; printf '%s' "$n"; }

# ── S0. SAFETY PROBE: a dirty bin/ refuses at rc 30 inside the scratch tree ─
fixture s0
gitmode off
echo probe >> "$CK/bin/x.sh"
sync
if [ "$RC" != 30 ] || ! grep -q 'harness sync REFUSED' "$ALERTS" 2>/dev/null; then
  echo "FAIL: bin/harness-sync.sh does not honour \$HARNESS (rc=$RC) — refusing to run the deploy path."
  echo "harness-sync-self-heal.bh-7382-test: $PASS pass, $((FAIL+1)) fail"
  exit 1
fi
ok

# ── a1. fails once on a clean tree: reset, rc 0 ─────────────────────────────
fixture a1
gitmode once
sync
[ "$RC" = 0 ] && ok || bad "a1: rc 0 after the reset, got $RC: $(cat "$T/out.txt") $(cat "$T/err.txt")"
[ "$(head_sha)" = "$ORIGIN_SHA" ] && ok || bad "a1: HEAD = origin/main ($(head_sha) vs $ORIGIN_SHA)"
grep 'reset to origin/main' "$LOG" 2>/dev/null | grep -qF 'cannot lock ref' && ok \
  || bad "a1: update-runners.log has the reset line with the stderr: $(cat "$LOG" 2>/dev/null)"
[ "$(nlines "$ALERTS" 'cannot fast-forward')" = 0 ] && ok || bad "a1: a healed tick writes no ALERTS line: $(cat "$ALERTS" 2>/dev/null)"

# ── a2. tracked docs/ edit + always failing: rc 20, alert with stderr ───────
fixture a2
gitmode always
echo 'local edit' >> "$CK/docs/x.md"
sync
[ "$RC" = 20 ] && ok || bad "a2: rc 20, got $RC: $(cat "$T/out.txt")"
case "$(head -1 "$T/out.txt")" in
  "pull-failed: fatal: cannot lock ref"*) ok ;;
  *) bad "a2: stdout starts with 'pull-failed: fatal: cannot lock ref': $(cat "$T/out.txt")" ;;
esac
[ "$(nlines "$ALERTS" 'cannot fast-forward')" = 1 ] && ok || bad "a2: exactly one ALERTS line: $(cat "$ALERTS" 2>/dev/null)"
AL=$(grep -F 'cannot fast-forward' "$ALERTS" 2>/dev/null)
case "$AL" in *"$LOCKERR"*) ok ;; *) bad "a2: the ALERTS line carries the stderr: $AL" ;; esac
case "$AL" in *"tracked files modified: docs/x.md"*) ok ;; *) bad "a2: the ALERTS line names docs/x.md: $AL" ;; esac
[ "$(head_sha)" = "$START_SHA" ] && ok || bad "a2: HEAD unchanged ($(head_sha) vs $START_SHA)"
grep -q 'local edit' "$CK/docs/x.md" && ok || bad "a2: the docs edit is still on disk"
[ "$(sed -n 2p "$H/state/harness-sync-last-refused" 2>/dev/null)" = pull-failed ] && ok \
  || bad "a2: the refused stamp content stays 'pull-failed': $(cat "$H/state/harness-sync-last-refused" 2>/dev/null)"

# ── a5. a2 again in the same hour: still exactly 1 ALERTS line ──────────────
sync
[ "$RC" = 20 ] && ok || bad "a5: the second run is rc 20 too, got $RC"
[ "$(nlines "$ALERTS" 'cannot fast-forward')" = 1 ] && ok || bad "a5: still one ALERTS line in the hour: $(cat "$ALERTS" 2>/dev/null)"

# ── a3. next tick after a2: wrapper off, edit reverted -> rc 0 ──────────────
gitmode off
"$REAL_GIT" -C "$CK" checkout -q -- docs/x.md
sync
[ "$RC" = 0 ] && ok || bad "a3: rc 0 on the next tick, got $RC: $(cat "$T/out.txt")"
[ "$(head_sha)" = "$ORIGIN_SHA" ] && ok || bad "a3: HEAD = origin/main ($(head_sha) vs $ORIGIN_SHA)"

# ── a4. untracked bin/new.sh in the way, always failing: displaced + reset ──
fixture a4
gitmode always
printf 'old local content\n' > "$CK/bin/new.sh"
sync
[ "$RC" = 0 ] && ok || bad "a4: rc 0 after the reset, got $RC: $(cat "$T/out.txt") $(cat "$T/err.txt")"
[ "$(head_sha)" = "$ORIGIN_SHA" ] && ok || bad "a4: HEAD = origin/main ($(head_sha) vs $ORIGIN_SHA)"
DISP=$(find "$H/state/harness-sync-displaced" -path '*/bin/new.sh' 2>/dev/null | head -1)
[ -n "$DISP" ] && grep -q 'old local content' "$DISP" && ok \
  || bad "a4: the old bin/new.sh is kept under state/harness-sync-displaced/*/bin/new.sh: $(find "$H/state" 2>/dev/null)"
grep -q 'new-from-origin' "$CK/bin/new.sh" && ok || bad "a4: the checkout has origin's bin/new.sh"

# ── a7. the displaced dir keeps only the 5 newest stamp dirs ────────────────
fixture a7
gitmode always
for s in 20300101T000000Z 20300102T000000Z 20300103T000000Z 20300104T000000Z 20300105T000000Z 20300106T000000Z; do
  mkdir -p "$H/state/harness-sync-displaced/$s"
done
printf 'old local content\n' > "$CK/bin/new.sh"
sync
[ "$RC" = 0 ] && ok || bad "a7: rc 0 after the reset, got $RC: $(cat "$T/out.txt")"
KEPT=$(cd "$H/state/harness-sync-displaced" && ls | tr '\n' ' ')
[ "$KEPT" = "20300103T000000Z 20300104T000000Z 20300105T000000Z 20300106T000000Z 20330518T033320Z " ] && ok \
  || bad "a7: the 5 newest stamp dirs stay, this run's included: $KEPT"

# ── a6. no failure: the normal path never resets ────────────────────────────
fixture a6
gitmode off
sync
[ "$RC" = 0 ] && ok || bad "a6: rc 0, got $RC: $(cat "$T/out.txt")"
[ "$(head_sha)" = "$ORIGIN_SHA" ] && ok || bad "a6: HEAD = origin/main"
[ "$(nlines "$LOG" 'reset')" = 0 ] && ok || bad "a6: no reset line in update-runners.log: $(grep reset "$LOG")"

echo "harness-sync-self-heal.bh-7382-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
