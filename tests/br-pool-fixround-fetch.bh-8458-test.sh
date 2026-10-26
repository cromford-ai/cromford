#!/bin/bash
# tests/br-pool-fixround-fetch.bh-8458-test.sh — BH-8458: a fix round on a
# single-branch clone fetches the PR branch by name, a worktree-add failure
# carries git's own (redacted) line to the hub, and N such failures in a row
# for one project send ONE alert.
#
# WHY. The pool image bakes the repo with `git clone --depth 50`, which implies
# --single-branch: `git fetch origin` maps main only, origin/ticket/<key> never
# exists, `worktree add ... origin/ticket/<key>` fails, and the reason said "see
# the git error in logs/blocked-resolver.log", a log on a machine the reap had
# already destroyed. project-6-os FXR-1087, 1095, 1096, 1097 (2026-10-26).
#
#   F1  a --depth 50 clone (main-only refspec): the round reaches the agent,
#       origin/ticket/TK-88 resolves in the clone, and the PR branch moves
#   F2  a blocked worktree add: FIX_RESULT setup-blocked carries `git: fatal:`
#       and git's "already ... worktree" text, not the old "see the log" text;
#       no rung counted
#   F3  a git shim prints a token on the add: the decoded detail is redacted
#   F4  br_fix_adopt (lifted) given F2's row writes the git line into the hub
#       log and counts the streak
#   S1-S7  br_wt_streak: count, negatives, resets, a new shell, alert once,
#       an unwritable state dir, the knob
#   Z1  0 curl / flyctl calls (all remotes are file://, gh is the fixture stub)
#
# Drives the REAL script through `--fix-here`, the way bin/fix-round-claim.sh
# runs it, over the fx_br_ladder_git origin.
# Run from anywhere: tests/br-pool-fixround-fetch.bh-8458-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

# shellcheck source=tests/lib/fixture-harness.sh
. "$DIR/tests/lib/fixture-harness.sh" || exit 1
H="$T/h"
mkdir -p "$H/bin/blocked-resolver.d"
cp "$DIR/bin/blocked-resolver.sh" "$DIR/bin/fly-pool.sh" "$DIR/bin/merge-sweep.sh" \
   "$DIR/bin/merge-conductor.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/project-of.sh" \
   "$DIR/bin/box-for.sh" "$H/bin/" || exit 1
fx_br_harness "$DIR" "$T" || exit 1
for lib in bin/lib/hub-box.sh bin/lib/heartbeat.sh bin/lib/lane-gate.sh; do
  scratch_install_closure "$lib" "$H" >/dev/null || { echo "FAIL: closure of $lib"; exit 1; }
done
cp "$DIR"/bin/blocked-resolver.d/*.sh "$H/bin/blocked-resolver.d/" || exit 1
scratch_install_closure bin/lib/token-redact.sh "$H" >/dev/null || { echo "FAIL: closure of token-redact.sh"; exit 1; }
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
mrs_fixture "$H" tproj
[ -d "$DIR/bin/lib/br" ] || exit 1   # impact: this suite runs when bin/lib/br/ changes
fx_br_ladder_git "$DIR" "$T" || exit 1

# Z1: curl and flyctl record a call and fail. The suite must make none.
for v in curl flyctl; do
  printf '#!/bin/bash\nprintf "%%s %%s\\n" %s "$*" >> "%s/vendor-calls.txt"\nexit 1\n' "$v" "$T" > "$T/fakebin/$v"
  chmod +x "$T/fakebin/$v"
done
: > "$T/vendor-calls.txt"

cat > "$H/bin/agent-call.sh" <<AGENT
#!/bin/bash
printf '%s\n' "\$*" >> "$T/agent.txt"
printf '%s' "\$6" > "$T/prompt.txt"
printf 'both sides, resolved\n' > a.txt
git add -A >/dev/null 2>&1
git commit -q -m "fix round: resolved the merge" >/dev/null 2>&1
exit 0
AGENT
chmod +x "$H/bin/agent-call.sh"

PR88="https://github.com/o/tproj/pull/88"
LOGF="$H/logs/blocked-resolver.log"
FIXHERE() { ( HARNESS="$H" FLEET_CONF="$H/fleet.conf" REPOS_ROOT="$T/repos" BOX_NAME=box-tproj \
              bash "$H/bin/blocked-resolver.sh" --fix-here tproj sfr-1 conflict-unresolvable "$PR88" - - < "$T/rec-in.json" ) > "$T/run.out" 2>&1
              cat "$T/run.out" >> "$T/run.log"; }
RESET() { # RESET <branch> <base>
  scratch_rm "$H/state/blocked-resolver"; scratch_rm "$H/tmp/brfix"
  : > "$LOGF"; : > "$T/agent.txt"; rm -f "$T/prompt.txt"
  git -C "$T/repos/tproj" worktree prune >/dev/null 2>&1
  git -C "$T/repos/tproj" for-each-ref --format='%(refname:short)' refs/heads/brfix/ \
    | while read -r b; do git -C "$T/repos/tproj" branch -D "$b" >/dev/null 2>&1; done
  printf '%s\n' "$1" > "$T/prbranch"; osha "$1" | tr -d '\n' > "$T/prhead"; printf '%s\n' "$2" > "$T/prbase"
  printf 'conductor: conflict-unresolvable\n' > "$T/findings"
  jq -nc '{project:"tproj",rkey:"sfr-1",fixrounds:0,rebuilds:0,mechanicals:1,outcome:"",attempts:[]}' > "$T/rec-in.json"
}
SINGLE() { # the pool image's clone: --depth implies --single-branch
  rm -rf "$T/repos/tproj"
  git clone -q --depth 50 "file://$T/origin.git" "$T/repos/tproj"
  git -C "$T/repos/tproj" config user.email t@t; git -C "$T/repos/tproj" config user.name t
}
SETUP_DETAIL() { # the decoded FIX_RESULT setup-blocked detail of the last run
  sed -n 's/^FIX_RESULT setup-blocked //p' "$T/run.out" | tail -n 1 | base64 -d 2>/dev/null
}

# ── F1: a single-branch clone, a PR branch the clone has never seen
SINGLE
[ "$(git -C "$T/repos/tproj" config --get-all remote.origin.fetch)" = "+refs/heads/main:refs/remotes/origin/main" ] && ok \
  || bad "F1 rig: the clone must map main only (got $(git -C "$T/repos/tproj" config --get-all remote.origin.fetch))"
git -C "$T/repos/tproj" rev-parse --verify -q origin/ticket/TK-88 >/dev/null && bad "F1 rig: origin/ticket/TK-88 must not resolve before the round" || ok
RESET ticket/TK-88 main
C0=$(osha ticket/TK-88)
FIXHERE
[ -s "$T/prompt.txt" ] && ok || bad "F1: the round never reached the agent (out: $(SETUP_DETAIL); log: $(tail -3 "$LOGF"))"
git -C "$T/repos/tproj" rev-parse --verify -q origin/ticket/TK-88 >/dev/null && ok || bad "F1: origin/ticket/TK-88 must resolve in the clone after the round"
[ "$(osha ticket/TK-88)" != "$C0" ] && ok || bad "F1: the round must push a new head (log: $(tail -3 "$LOGF"))"
grep -q '^FIX_RESULT setup-blocked' "$T/run.out" && bad "F1: no setup-blocked on a single-branch clone (got: $(SETUP_DETAIL))" || ok

# ── F2: the worktree add is blocked (8f-6 shape): brfix/<ck> is checked out
#    elsewhere and does not contain the PR head, so reuse declines.
git clone -q "file://$T/origin.git" "$T/full" && rm -rf "$T/repos/tproj" && mv "$T/full" "$T/repos/tproj"
git -C "$T/repos/tproj" config user.email t@t; git -C "$T/repos/tproj" config user.name t
RESET ticket/TK-89 main
CK=sfr-1   # --fix-here with tkey "-": the cap key is the rkey (br_cap_key)
BLKWT="$T/blkwt"
git -C "$T/repos/tproj" worktree add -q "$BLKWT" -b "brfix/$CK" origin/main 2>/dev/null
FIXHERE
D2=$(SETUP_DETAIL)
F2ROW=$(grep '^FIX_RESULT setup-blocked' "$T/run.out" | tail -n 1)
case "$D2" in "worktree add failed for origin/ticket/TK-89"*) ok ;; *) bad "F2: the decoded detail must start 'worktree add failed for origin/ticket/TK-89' (got '$D2'; out: $(tail -3 "$T/run.out"))" ;; esac
case "$D2" in *"git: fatal:"*) ok ;; *) bad "F2: the detail must carry git's fatal line (got '$D2')" ;; esac
case "$D2" in *already*worktree*|*"already checked out"*) ok ;; *) bad "F2: the detail must carry git's own reason (got '$D2')" ;; esac
case "$D2" in *"see the git error in logs/blocked-resolver.log"*) bad "F2: the old pointer to a reaped log must be gone (got '$D2')" ;; *) ok ;; esac
[ "$(sed -n 's/^FIX_RECORD //p' "$T/run.out" | tail -n 1 | base64 -d 2>/dev/null | jq -r '.fixrounds // 0' 2>/dev/null)" = 0 ] && ok \
  || bad "F2: a worktree-add failure counts no fix round (out: $(grep FIX_RECORD "$T/run.out" | head -c 200))"
git -C "$T/repos/tproj" worktree remove --force "$BLKWT" >/dev/null 2>&1
git -C "$T/repos/tproj" branch -D "brfix/$CK" >/dev/null 2>&1

# ── F3: git prints a credential on the add; the posted detail is redacted.
RESET ticket/TK-89 main
REALGIT=$(command -v git)
cat > "$T/fakebin/git" <<EOF
#!/bin/bash
case " \$* " in
  *" worktree add "*"origin/ticket/TK-89"*)
    echo "Preparing worktree (resetting branch)" >&2
    echo "fatal: unable to access 'https://x-access-token:tok-fixture-1@github.com/o/tproj.git/': ghp_fixtureFIXTUREfixtureFIXTUREfixture00" >&2
    exit 128 ;;
esac
exec "$REALGIT" "\$@"
EOF
chmod +x "$T/fakebin/git"
FIXHERE
rm -f "$T/fakebin/git"
D3=$(SETUP_DETAIL)
case "$D3" in *"unable to access"*) ok ;; *) bad "F3: the shim's fatal line must be the one carried (got '$D3')" ;; esac
case "$D3" in *tok-fixture-1*) bad "F3: the clone-URL credential must be redacted (got '$D3')" ;; *) ok ;; esac
case "$D3" in *ghp_fixture*) bad "F3: the ghp_ token must be redacted (got '$D3')" ;; *) ok ;; esac
case "$D3" in *redacted*) ok ;; *) bad "F3: the detail must say what was redacted (got '$D3')" ;; esac
grep -q 'tok-fixture-1\|ghp_fixtureFIXTURE' "$T/run.out" && bad "F3: no token in the round's stdout" || ok

# ── F4, S*: the hub side, unit-driven.
U="$T/u"; mkdir -p "$U/state" "$U/bin/lib"
DRV="$DIR/bin/blocked-resolver.sh"
awk '/^br_fix_adopt\(\) \{/{f=1} f{print} f&&/^}/{exit}' "$DRV" > "$U/adopt.sh"
[ -s "$U/adopt.sh" ] && ok || bad "F4: br_fix_adopt could not be lifted"
scratch_install_closure bin/lib/token-redact.sh "$U" >/dev/null || bad "F4: closure of token-redact.sh"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/alerts"\nexit 0\n' "$U" > "$U/bin/lane-alert.sh"; chmod +x "$U/bin/lane-alert.sh"
cat > "$T/u-pre.sh" <<EOF
set -u
H="$U"; ST="$U/state"; LOG="$U/log"
say() { printf '%s\n' "\$*" >> "\$LOG"; }
br_load() { printf '{}'; }
br_save() { :; }
fix_round_adopt() { return 0; }
br_setup_blocked() { say "\$1/\$3 [\$4]: the fix round could not START (\$6)"; }
. "$DIR/bin/blocked-resolver.d/bh-8458-wt-streak.sh"
EOF
UNIT() { ( . "$T/u-pre.sh"; . "$U/adopt.sh"; eval "$1" ) >/dev/null 2>&1; }
STREAK() { ( . "$T/u-pre.sh"; br_wt_streak tproj box-a "$1" ) >/dev/null 2>&1; }
SCOUNT() { cut -f1 "$U/state/tproj/wt-fail-streak" 2>/dev/null; }
SALERTED() { cut -f2 "$U/state/tproj/wt-fail-streak" 2>/dev/null; }
NALERT() { grep -c -- '^--id br-wt-streak:tproj' "$U/alerts" 2>/dev/null || true; }
URESET() { scratch_rm "$U/state/tproj"; : > "$U/log"; : > "$U/alerts"; }
B64() { printf '%s' "$1" | base64 -w0; }

URESET
ROWJ=$(jq -nc --arg r "${F2ROW#FIX_RESULT }" '{id:"FXR-1",claimed_by:"box-tproj",result:$r}')
UNIT "br_fix_adopt tproj sfr-1 conflict-unresolvable $PR88 - TK-89 tproj-TK-89 '$ROWJ'"
grep -q 'git: fatal:' "$U/log" && ok || bad "F4: the hub log must carry git's line from the posted row (log: $(cat "$U/log"))"
[ "$(SCOUNT)" = 1 ] && ok || bad "F4: br_fix_adopt must count the worktree-add failure (file: $(cat "$U/state/tproj/wt-fail-streak" 2>/dev/null))"

C1="worktree add failed for origin/ticket/TK-2350 in /data/repos/project-6-os: git: fatal: invalid reference: origin/ticket/TK-2350"
C2="worktree add failed for origin/ticket/TK-2350 in /data/repos/project-6-os — see the git error in logs/blocked-resolver.log"
# S1: both texts count.
URESET
STREAK "setup-blocked $(B64 "$C1")"; STREAK "setup-blocked $(B64 "$C2")"
[ "$(SCOUNT)" = 2 ] && [ "$(SALERTED)" = 0 ] && ok || bad "S1: two worktree-add failures count 2, not alerted (file: $(cat "$U/state/tproj/wt-fail-streak" 2>/dev/null))"
[ "$(NALERT)" = 0 ] && ok || bad "S1: no alert under the threshold"
# S2: the negatives leave the count.
URESET; STREAK "setup-blocked $(B64 "$C1")"
for neg in "setup-blocked $(B64 'origin/ticket/TK-93 will not resolve in /root/repos/tproj (the fetch did not run)')" \
           "setup-blocked $(B64 'the Fly pool machine for box-project-6-os-1 could not start the round: warm-up failed')" \
           "setup-blocked $(B64 'there is no local clone at /root/repos/tproj')" \
           "setup-blocked $(B64 'REBASE_SETUP_FAILED worktree add failed')" \
           "box-paused $(B64 'worktree add failed for origin/x')" \
           'setup-blocked !!!not-base64!!!' 'setup-blocked ' 'something-new'; do
  STREAK "$neg"
  [ "$(SCOUNT)" = 1 ] && ok || bad "S2: '$neg' must leave the count at 1 (got $(SCOUNT))"
done
# S3: resets.
for w in done terminal rebuild-fresh; do
  URESET; STREAK "setup-blocked $(B64 "$C1")"; STREAK "setup-blocked $(B64 "$C1")"
  STREAK "$w"
  [ -e "$U/state/tproj/wt-fail-streak" ] && bad "S3: '$w' must reset the streak" || ok
done
URESET; STREAK "setup-blocked $(B64 "$C1")"; STREAK "box-paused $(B64 x)"
[ "$(SCOUNT)" = 1 ] && ok || bad "S3: box-paused leaves the count"
# S4: two counts, the third in a new shell process.
URESET
STREAK "setup-blocked $(B64 "$C1")"; STREAK "setup-blocked $(B64 "$C1")"
bash -c ". '$T/u-pre.sh'; br_wt_streak tproj box-b 'setup-blocked $(B64 "$C1")'" >/dev/null 2>&1
[ "$(NALERT)" = 1 ] && ok || bad "S4: the third failure sends one alert (alerts: $(cat "$U/alerts"))"
grep -q 'lane_placement.blocked-resolver-fix.tproj=box' "$U/alerts" && ok || bad "S4: the alert names the kill knob (alerts: $(cat "$U/alerts"))"
grep -q 'box-b' "$U/alerts" && grep -q 'invalid reference' "$U/alerts" && ok || bad "S4: the alert names the last box and git's line"
grep -q 'WT-STREAK tproj 3/3' "$U/log" && ok || bad "S4: the log line reads the count (log: $(cat "$U/log"))"
[ "$(SALERTED)" = 1 ] && ok || bad "S4: the file records the alert"
# S5: alert once; a reset re-arms it.
URESET
for _ in 1 2 3 4 5; do STREAK "setup-blocked $(B64 "$C1")"; done
[ "$(NALERT)" = 1 ] && ok || bad "S5: five failures send exactly 1 alert (got $(NALERT))"
STREAK done
grep -q -- '--resolve --id br-wt-streak:tproj' "$U/alerts" && ok || bad "S5: a reset after an alert resolves the alert id"
for _ in 1 2 3; do STREAK "setup-blocked $(B64 "$C1")"; done
[ "$(NALERT)" = 2 ] && ok || bad "S5: a new streak after a reset alerts again (alerts: $(cat "$U/alerts"))"
# S6: the state dir cannot be written (a file where the dir goes; root ignores modes).
URESET; printf 'x' > "$U/state/tproj"
( . "$T/u-pre.sh"; br_wt_streak tproj box-a "setup-blocked $(B64 "$C1")" ) >/dev/null 2>&1; rc=$?
[ "$rc" = 0 ] && ok || bad "S6: rc 0 on an unwritable state dir (got $rc)"
[ "$(grep -c WT-STREAK "$U/log")" = 1 ] && ok || bad "S6: one log line (log: $(cat "$U/log"))"
[ "$(NALERT)" = 0 ] && ok || bad "S6: no alert"
rm -f "$U/state/tproj"
# S7: the knob.
URESET
for _ in 1 2; do STREAK "setup-blocked $(B64 "$C1")"; done
[ "$(NALERT)" = 0 ] && ok || bad "S7: unset knob: 2 failures do not alert"
STREAK "setup-blocked $(B64 "$C1")"
[ "$(NALERT)" = 1 ] && ok || bad "S7: unset knob: the default threshold is 3"
URESET
for _ in 1 2 3 4 5 6 7 8 9 10; do ( . "$T/u-pre.sh"; BR_WT_FAIL_STREAK=0 br_wt_streak tproj box-a "setup-blocked $(B64 "$C1")" ) >/dev/null 2>&1; done
[ -e "$U/state/tproj/wt-fail-streak" ] && bad "S7: 0 = off, no file" || ok
[ "$(NALERT)" = 0 ] && ok || bad "S7: 0 = off, no alert"
URESET
for _ in 1 2 3; do ( . "$T/u-pre.sh"; BR_WT_FAIL_STREAK=abc br_wt_streak tproj box-a "setup-blocked $(B64 "$C1")" ) >/dev/null 2>&1; done
[ "$(NALERT)" = 1 ] && ok || bad "S7: 'abc' falls back to 3"
grep -q "BR_WT_FAIL_STREAK='abc'" "$U/log" && ok || bad "S7: a bad knob is logged (log: $(cat "$U/log"))"

# ── Z1
[ -s "$T/vendor-calls.txt" ] && bad "Z1: the suite made vendor calls: $(cat "$T/vendor-calls.txt")" || ok

echo "br-pool-fixround-fetch.bh-8458: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
