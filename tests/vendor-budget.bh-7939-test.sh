#!/bin/bash
# tests/vendor-budget.bh-7939-test.sh — the 0-vendor-call budget of the PR
# suite (BH-7974, slice BH-7939.0; iron law BH-7563 rule 6).
#
# PATH stubs for curl, flyctl, fly, ssh and tailscale append
# `<epoch> stub <name>` to $VENDOR_CALL_LOG and exit 99. Every path is a glob,
# so a sibling adds a suite or a seam and never edits this file.
#   B1  HARNESS_VENDOR_MODE=fake: every tests/*bh-7939*-test.sh but this one
#       passes and the call log stays at 0 lines
#   B2  mutation: real mode, one tg_latest_chat_id -> exactly 1 `stub curl` line
#       and 1 `telegram getUpdates` seam line; fake mode after it -> 0 new lines
#   B3  lint: no NEW getUpdates / `machine(s) run` call in bin/, worker/*/src or
#       console-ui/src outside bin/lib/vendor/ and the allow-list; B3b
#       tests/contract/ stays out of the CI loop `tests/*.sh tests/mc/*.sh`
#   B4  every bin/lib/vendor/*.sh: bash -n, shellcheck -S error, a silent
#       source with no `set` or trap change (a BH-7965 proof seam, which is run
#       and never sourced: rc 99 on an unknown verb, 0 calls); seam cases S1-S6
#   B5  console-ui/src/api.js still loads, firstRunApi and flyApi are factories,
#       and the spreads removed no key of `api`
# Run: HARNESS_TEST_SANDBOX=1 bash tests/vendor-budget.bh-7939-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: expected '$3', got '$2'"; fi; }
has() { if grep -qF -- "$3" <<<"$2"; then ok; else bad "$1: '$3' not in: $2"; fi; }
SELF="$(basename "$0")"
TOK='123456:tok-fixture-BUDGET'

# stubs <dir> — the vendor CLIs, each logging to $VENDOR_CALL_LOG and exiting 99.
stubs() {
  mkdir -p "$1"
  local n
  for n in curl flyctl fly ssh tailscale; do
    printf '#!/bin/bash\nprintf "%%s stub %s\\n" "$(date -u +%%s)" >> "${VENDOR_CALL_LOG:-/dev/null}"\nexit 99\n' "$n" > "$1/$n"
    chmod +x "$1/$n"
  done
}
count() { local n=0; [ -f "$1" ] && n=$(grep -c . "$1"); echo "$n"; }

# B1 — every wave-6 suite under fake mode makes 0 vendor calls.
mkdir -p "$T/b1"; stubs "$T/b1/stub-bin"; : > "$T/b1/calls.log"
n=0
for s in "$DIR"/tests/*bh-7939*-test.sh; do
  [ -f "$s" ] || continue
  [ "$(basename "$s")" = "$SELF" ] && continue
  n=$((n+1))
  env PATH="$T/b1/stub-bin:$PATH" HARNESS_VENDOR_MODE=fake VENDOR_CALL_LOG="$T/b1/calls.log" \
    bash "$s" >"$T/b1/out.$n" 2>&1; rc=$?
  eq "B1 $(basename "$s") rc" "$rc" 0
  [ "$rc" = 0 ] || tail -n 20 "$T/b1/out.$n"
done
[ "$n" -ge 1 ] && ok || bad "B1 found no tests/*bh-7939*-test.sh to run"
eq "B1 0 vendor calls in fake mode" "$(count "$T/b1/calls.log")" 0

# B2 — the stubs and the seam log do count a real call (the budget can fail).
mkdir -p "$T/b2"; stubs "$T/b2/stub-bin"; : > "$T/b2/calls.log"
env PATH="$T/b2/stub-bin:$PATH" HARNESS_VENDOR_MODE=real VENDOR_CALL_LOG="$T/b2/calls.log" TELEGRAM_BOT_TOKEN="$TOK" \
  bash -c '. "$1" || exit 98; tg_latest_chat_id TELEGRAM_BOT_TOKEN' _ "$DIR/bin/lib/vendor/telegram.sh" >"$T/b2/out" 2>&1; rc=$?
eq "B2 the stub curl failure is rc 1" "$rc" 1
eq "B2 exactly 1 stub curl line" "$(grep -c ' stub curl$' "$T/b2/calls.log")" 1
eq "B2 exactly 1 seam line" "$(grep -c ' telegram getUpdates$' "$T/b2/calls.log")" 1
env PATH="$T/b2/stub-bin:$PATH" HARNESS_VENDOR_MODE=fake VENDOR_CALL_LOG="$T/b2/calls.log" TELEGRAM_BOT_TOKEN="$TOK" \
  VENDOR_FAKE_DIR="$DIR/tests/fakes/vendor" \
  bash -c '. "$1" || exit 98; tg_latest_chat_id TELEGRAM_BOT_TOKEN' _ "$DIR/bin/lib/vendor/telegram.sh" >"$T/b2/out" 2>&1; rc=$?
eq "B2 fake mode answers the seed" "$rc $(cat "$T/b2/out")" "0 -1009990001"
eq "B2 fake mode adds 0 lines" "$(count "$T/b2/calls.log")" 2

# B3 — a NEW vendor call outside its seam is refused.
# The allow-list is every file that held a match on main when the seam landed:
#   git grep -lE 'getUpdates|\bmachines? run\b' origin/main -- bin 'worker/*/src' console-ui/src
# bin/lib/box-move/provision.sh joined main later (BH-8322); its match is the
# bm_fail text after hmf_machine_run, which bin/lib/hub-move-fly.sh holds.
VB_ALLOW=" bin/fly-image-build.sh bin/fly-pool-probe-pull.sh bin/fly-pool-project.sh bin/fly-pool-rollout.sh
 bin/fly-pool-secrets-sync.sh bin/fly-pool.sh bin/fly-provision.sh bin/hub-move.sh bin/lane-fleet.sh
 bin/lane-reaper.sh bin/lib/hub-move-fly.sh bin/lib/lane-move/pipeline-health.sh bin/lib/lane-move/stuck-work.sh
 bin/lib/mc/fly-workers.sh bin/lib/pool-account.sh bin/lib/pool-placement.sh bin/pool-budget.sh
 bin/pool-tick-summary.sh bin/sync-agent-rules.sh bin/lib/box-move/provision.sh "
VB_PAT='getUpdates|\bmachines? run\b'
# vb_lint <tree> — print `<rel>:<line>` for each non-comment vendor call outside
# bin/lib/vendor/ and the allow-list.
vb_lint() {
  local tree="$1" l f rel rest num text
  local -a where=("$tree/bin")
  local w
  for w in "$tree"/worker/*/src "$tree/console-ui/src"; do [ -d "$w" ] && where+=("$w"); done
  grep -rnE "$VB_PAT" "${where[@]}" 2>/dev/null | while IFS= read -r l; do
    f="${l%%:*}"; rest="${l#*:}"; num="${rest%%:*}"; text="${rest#*:}"
    rel="${f#"$tree"/}"
    case "$rel" in bin/lib/vendor/*) continue ;; esac
    case "$VB_ALLOW" in *[[:space:]]"$rel"[[:space:]]*) continue ;; esac
    [[ "$text" =~ ^[[:space:]]*(#|//) ]] && continue
    printf '%s:%s\n' "$rel" "$num"
  done
}
eq "B3 the real tree has 0 findings" "$(vb_lint "$DIR")" ""
mkdir -p "$T/b3/bin/lib/vendor"
echo 'curl -sS "https://api.telegram.org/bot$TOK/getUpdates"' > "$T/b3/bin/x.sh"
eq "B3 a new call is 1 finding" "$(vb_lint "$T/b3")" "bin/x.sh:1"
echo '  # curl -sS "https://api.telegram.org/bot$TOK/getUpdates"' > "$T/b3/bin/x.sh"
eq "B3 the same text as a comment is 0" "$(vb_lint "$T/b3")" ""
echo 'flyctl machines run img' > "$T/b3/bin/lib/vendor/y.sh"
echo 'flyctl machine run img' > "$T/b3/bin/fly-pool.sh"
eq "B3 inside the seam and the allow-list is 0" "$(vb_lint "$T/b3")" ""
echo 'flyctl machine run img' > "$T/b3/bin/fly-pool-new.sh"
eq "B3 machine run in a new file is 1" "$(vb_lint "$T/b3")" "bin/fly-pool-new.sh:1"

# B3b — the contract suites stay out of the PR CI loop.
[ -n "$(compgen -G "$DIR/tests/contract/*.contract-test.sh")" ] && ok || bad "B3b no tests/contract/*.contract-test.sh"
eq "B3b the CI loop globs miss tests/contract" "$( { compgen -G "$DIR/tests/*.sh"; compgen -G "$DIR/tests/mc/*.sh"; } | grep -c '/tests/contract/')" 0
# bin/test-trace-safety.sh --gate (the harness-ci shard step) and
# bin/test-impact.sh ti_suites sweep exactly those two globs.
eq "B3b the CI runners never name tests/contract" "$(cat "$DIR/.github/workflows/harness-ci.yml" "$DIR/bin/test-trace-safety.sh" "$DIR/bin/test-impact.sh" | grep -c 'tests/contract')" 0

# B4 — every seam file is valid, silent on source, and changes no shell state.
nf=0
for f in "$DIR"/bin/lib/vendor/*.sh; do
  [ -f "$f" ] || continue
  nf=$((nf+1)); rel="${f#"$DIR"/}"
  bash -n "$f" && ok || bad "B4 bash -n $rel"
  if command -v shellcheck >/dev/null 2>&1; then
    shellcheck -S error "$f" && ok || bad "B4 shellcheck $rel"
  else
    [ "$nf" = 1 ] && echo "SKIP shellcheck: not installed"
  fi
  # A BH-7965 proof seam (claude.sh, xai.sh, fake.sh, ...) is a command, not a
  # library: it finds _common.sh through "$(dirname "$0")", so it is run, never
  # sourced. Its contract for an unknown verb is rc 99, `unimplemented: <verb>`
  # on stderr, and 0 vendor calls (bin/lib/vendor/_common.sh).
  if grep -qF '"$(dirname "$0")' "$f"; then
    mkdir -p "$T/b4"; [ -d "$T/b4/stub-bin" ] || stubs "$T/b4/stub-bin"; : > "$T/b4/calls.log"
    o=$(env -i PATH="$T/b4/stub-bin:$PATH" VENDOR_CALL_LOG="$T/b4/calls.log" bash "$f" Bogus-verb </dev/null 2>&1); rc=$?
    eq "B4 run $rel Bogus-verb rc" "$rc" 99
    eq "B4 run $rel Bogus-verb says unimplemented" "$o" "unimplemented: Bogus-verb"
    eq "B4 run $rel Bogus-verb makes 0 vendor calls" "$(count "$T/b4/calls.log")" 0
    continue
  fi
  o=$(env -i PATH="$PATH" bash -c 'a="$-"; t0=$(trap -p); . "$1" || exit 9; [ "$a" = "$-" ] || echo "set changed"; [ "$(trap -p)" = "$t0" ] || trap -p' _ "$f" 2>&1); rc=$?
  eq "B4 source $rel rc" "$rc" 0
  eq "B4 source $rel is silent" "$o" ""
done
# The seams this slice ships; the glob above covers the ones siblings add.
for f in "$DIR/bin/lib/vendor/seam.sh" "$DIR/bin/lib/vendor/telegram.sh" \
         "$DIR/bin/lib/vendor/fly-machines.sh" "$DIR/bin/lib/vendor/tailscale.sh"; do
  [ -f "$f" ] && ok || bad "B4 missing ${f#"$DIR"/}"
done

SEAM="$DIR/bin/lib/vendor/seam.sh"
# sm <env...> -- <cmd> — run a seam function in a child bash; prints out, err, rc.
sm() {
  local -a e=()
  while [ "$1" != -- ]; do e+=("$1"); shift; done; shift
  local out rc
  out=$(env "${e[@]}" bash -c '. "$1" || exit 98; shift; "$@"' _ "$SEAM" "$@" 2>"$T/sm.err"); rc=$?
  printf '%s|rc=%s|err=%s' "$out" "$rc" "$(cat "$T/sm.err")"
}
# S1 — the mode table; an unknown value fails closed.
eq "S1 unset -> real" "$(sm -u HARNESS_VENDOR_MODE -- vendor_mode)" "real|rc=0|err="
eq "S1 real -> real" "$(sm HARNESS_VENDOR_MODE=real -- vendor_mode)" "real|rc=0|err="
eq "S1 empty -> real" "$(sm HARNESS_VENDOR_MODE= -- vendor_mode)" "real|rc=0|err="
eq "S1 fake -> fake" "$(sm HARNESS_VENDOR_MODE=fake -- vendor_mode)" "fake|rc=0|err="
eq "S1 Fake -> rc 2" "$(sm HARNESS_VENDOR_MODE=Fake -- vendor_mode)" "|rc=2|err=vendor-mode: unknown 'Fake'"
eq "S1 'fake ' -> rc 2" "$(sm "HARNESS_VENDOR_MODE=fake " -- vendor_mode)" "|rc=2|err=vendor-mode: unknown 'fake '"
# S2 — an unseeded method, key or vendor is rc 70.
mkdir -p "$T/s/fake"; echo '{"m":{"ok":true,"k":{"v":1}},"n":null}' > "$T/s/fake/v.json"
eq "S2 unseeded method" "$(sm VENDOR_FAKE_DIR="$T/s/fake" -- vendor_fake v nope)" "|rc=70|err=vendor-fake: v.nope not implemented"
eq "S2 unseeded key" "$(sm VENDOR_FAKE_DIR="$T/s/fake" -- vendor_fake v m nokey)" "|rc=70|err=vendor-fake: v.m not implemented"
# S3 — a seeded method and key print compact JSON; a seeded null is an answer.
eq "S3 seeded method" "$(sm VENDOR_FAKE_DIR="$T/s/fake" -- vendor_fake v m)" '{"ok":true,"k":{"v":1}}|rc=0|err='
eq "S3 seeded key" "$(sm VENDOR_FAKE_DIR="$T/s/fake" -- vendor_fake v m k)" '{"v":1}|rc=0|err='
eq "S3 seeded null" "$(sm VENDOR_FAKE_DIR="$T/s/fake" -- vendor_fake v n)" 'null|rc=0|err='
eq "S3 default dir is the repo seed" "$(env -u VENDOR_FAKE_DIR bash -c '. "$1" && vendor_fake telegram getMe' _ "$SEAM" | jq -r '.result.is_bot')" true
# S4 — a missing seed file and a path-like vendor are rc 70.
eq "S4 no seed file" "$(sm VENDOR_FAKE_DIR="$T/s/fake" -- vendor_fake nofile m)" "|rc=70|err=vendor-fake: nofile.m not implemented"
eq "S4 ../ vendor" "$(sm VENDOR_FAKE_DIR="$T/s/fake/sub" -- vendor_fake ../v m)" "|rc=70|err=vendor-fake: ../v.m not implemented"
# S5 — vendor_fake makes no network call, even with the stub curl first on PATH.
mkdir -p "$T/s5"; stubs "$T/s5/stub-bin"; : > "$T/s5/calls.log"
sm PATH="$T/s5/stub-bin:$PATH" VENDOR_CALL_LOG="$T/s5/calls.log" HARNESS_VENDOR_MODE=fake VENDOR_FAKE_DIR="$T/s/fake" -- vendor_fake v m >/dev/null
eq "S5 vendor_fake writes 0 lines" "$(count "$T/s5/calls.log")" 0
# S6 — vendor_call_log: real mode appends one line; fake mode or no log writes nothing.
sm VENDOR_CALL_LOG="$T/s5/calls.log" HARNESS_VENDOR_MODE=fake -- vendor_call_log telegram getMe >/dev/null
eq "S6 fake mode writes nothing" "$(count "$T/s5/calls.log")" 0
eq "S6 no log set is rc 0" "$(sm -u VENDOR_CALL_LOG -u HARNESS_VENDOR_MODE -- vendor_call_log telegram getMe)" "|rc=0|err="
sm -u HARNESS_VENDOR_MODE VENDOR_CALL_LOG="$T/s5/calls.log" -- vendor_call_log telegram getMe >/dev/null
eq "S6 real mode writes one line" "$(grep -cE '^[0-9]+ telegram getMe$' "$T/s5/calls.log")" 1

# B5 — the console factories and the api object.
if command -v node >/dev/null 2>&1; then
  B5=$(node --input-type=module -e '
    const [a, f, y] = await Promise.all(process.argv.slice(1, 4).map((p) => import(p)));
    const fl = y.flyApi;
    const o = (v) => v !== null && typeof v === "object" && !Array.isArray(v);
    console.log([typeof f.firstRunApi, o(f.firstRunApi({})), typeof fl, o(fl({})),
      typeof a.api.fleet, Object.keys(a.api).length].join(" "));' "$DIR/console-ui/src/api.js" "$DIR/console-ui/src/api-first-run.js" "$DIR/console-ui/src/api-fly.js" 2>&1)
  read -r t1 o1 t2 o2 tf nk <<<"$B5"
  eq "B5 firstRunApi is a factory" "$t1 $o1" "function true"
  eq "B5 flyApi is a factory" "$t2 $o2" "function true"
  eq "B5 api.fleet is still a function" "$tf" function
  eq "B5 api.js spreads firstRunApi" "$(grep -cF "...firstRunApi({ get, post, coordPath })" "$DIR/console-ui/src/api.js")" 1
  eq "B5 api.js spreads flyApi" "$(grep -cF "...flyApi({ get, post, coordPath })" "$DIR/console-ui/src/api.js")" 1
  # The key count before the spreads, from the merge base, against this tree's
  # sibling modules.
  if base=$(git -C "$DIR" merge-base HEAD origin/main 2>/dev/null) && git -C "$DIR" cat-file -e "$base:console-ui/src/api.js" 2>/dev/null; then
    mkdir -p "$T/b5/src"; echo '{"type":"module"}' > "$T/b5/package.json"
    for e in "$DIR"/console-ui/src/*; do [ "$(basename "$e")" = api.js ] || ln -s "$e" "$T/b5/src/"; done
    git -C "$DIR" show "$base:console-ui/src/api.js" > "$T/b5/src/api.js"
    nb=$(node --input-type=module -e 'const a = await import(process.argv[1]); console.log(Object.keys(a.api).length)' "$T/b5/src/api.js" 2>&1)
    eq "B5 no key removed (base $nb, head $nk)" "$nk" "$nb"
  else
    echo "SKIP B5 key count: no merge base with origin/main"
  fi
else
  echo "SKIP B5: node not installed"
fi

echo "vendor-budget.bh-7939: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
