#!/bin/bash
# tests/mc-prequeue-fast-lints.bh-8473-test.sh — BH-8473: before the merge
# conductor enqueues a READY head, its pre-queue gate (pq_gate,
# bin/lib/mc-prequeue.sh) runs a fast lint set on the head MERGED ONTO CURRENT
# MAIN, through the hook bin/lib/mc-prequeue.d/fast-lints.sh and the runner
# bin/prequeue-fast-lints.sh. A red that is green on main parks the row
# `prequeue-red: <suites> on main <m12> — …`; it is never enqueued. The gate
# does this with MC_PREQUEUE_GATE=0 (BH-8062 shape B) and with it on.
#
# Part 1 sources the gate with a fixture catalog and a local bare origin:
#   H1  the merged tree holds both the head's and main's new files
#   H2  a clean head: `green`
#   H3  a red item: `red tests/x-test.sh`
#   H4  knob MC_PREQUEUE_FAST_LINTS=0: not wanted
#   H5  ACTIONS=0: not wanted
#   H6  a conflict: `none conflict`
#   H7  the work dir is removed on every path
#   H8  the git lock is busy: `none lock-busy`
#   H9  no gh, gh_rest, curl or mergify call in the whole suite
#   G1  MC_PREQUEUE_GATE=0, clean head: proceed, the READY arm enqueues
#   G5  gate off, fast lint knob 0, no restamp or mignum: no main-tip read
#   G6  gate on: the fast lint red wins before the cache read (no pq_resolve)
#   G7  MC_PREQUEUE_GATE=0, red head: red, PQ_SUITES names the suite, no PQ_PATH
#   K1  the PQ_KNOB_DEFAULTS values equal the knob fragments' defaults
#   K2  the settings row set limits the run
#   C1  a red baseline is cached per (main, id) and read on the next run
#
# Part 2 runs bin/merge-conductor.sh WHOLE (the READY arm, D2) on a copy of
# this repo's own tree, with the real catalog row `lanes-registry`:
#   A1  a head that adds a knob with a prose zero_means: BLOCKED_HUMAN
#       `prequeue-red: tests/lanes-registry-test.sh on main <m12> — …`, never
#       enqueued (G2)
#   G3  br_prequeue_brief reads that park reason: the suite and the main sha
#   G4  a second tick on the same head and main: one PREQUEUE_RED line
#   A2  a clean head on the same main: enqueued
#
# Real git, a local origin, no network. As root the hook runs the set as
# nobody (setpriv); as any other user the snapshot lib's setpriv steps are
# replaced by a run as this user (the lib refuses without root).
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/mc-prequeue-fast-lints.bh-8473-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq    >/dev/null || { echo "jq missing — skipping";    exit 0; }
command -v git   >/dev/null || { echo "git missing — skipping";   exit 0; }
command -v flock >/dev/null || { echo "flock missing — skipping"; exit 0; }
HOOK="$DIR/bin/lib/mc-prequeue.d/fast-lints.sh"
RUNNER="$DIR/bin/prequeue-fast-lints.sh"
CATALOG="$DIR/catalog/prequeue-fast-lints.tsv"
[ -f "$HOOK" ] || bad "setup: $HOOK does not exist"
[ -f "$RUNNER" ] || bad "setup: $RUNNER does not exist"
[ -f "$CATALOG" ] || bad "setup: $CATALOG does not exist"

# nobody must reach the work dirs under $T by their absolute path (as root).
chmod 711 "$T"
SLUG=o/r; NUM=31; GHURL="https://github.com/$SLUG.git"
O="$T/origin.git"; W="$T/work"; CL="$T/clone"
export GIT_CONFIG_GLOBAL="$T/gitconfig" GIT_CONFIG_NOSYSTEM=1
git config --global user.email t@example.invalid
git config --global user.name t
git config --global init.defaultBranch main
git config --global commit.gpgsign false
git config --global advice.detachedHead false
git config --global protocol.file.allow always
git config --global "url.$O.insteadOf" "$GHURL"
export MC_STATE_DIR="$T/state" MC_H="$T/h"
LOG="$T/log"; ATT="$T/att"; LOCKS="$T/locks"; TIPS="$T/tips"; RESOLVES="$T/resolves"
CALLS="$T/vendor-calls"; : > "$CALLS"; chmod 666 "$CALLS"

# The vendor fakes: every call is one line in $CALLS (H9). On PATH for the
# runner's children too (rp_snapshot_run passes PATH through).
mkdir -p "$T/fakebin"; chmod 755 "$T/fakebin"
for v in gh curl mergify; do
  printf '#!/bin/bash\necho "%s $*" >> "%s"\nexit 97\n' "$v" "$CALLS" > "$T/fakebin/$v"; chmod 755 "$T/fakebin/$v"
done
export PATH="$T/fakebin:$PATH"

# The scratch harness MC_H: the runner and a fixture catalog.
mkdir -p "$MC_H/catalog" "$MC_H/tmp"; chmod 711 "$MC_H" "$MC_H/tmp"
scratch_install_closure bin/prequeue-fast-lints.sh "$MC_H" >/dev/null || bad "setup: cannot install bin/prequeue-fast-lints.sh"
printf '%s\t%s\t%s\t%s\n' \
  lint 'bash tests/x-test.sh' tests/x-test.sh 'fixture: red when bad.txt exists' \
  mainside 'test -f mainfile.txt' tests/mainside-test.sh 'fixture: red when main'"'"'s file is missing' \
  headside '! test -f headfile.txt' tests/headside-test.sh 'fixture: red when the head'"'"'s file is present' \
  > "$MC_H/catalog/prequeue-fast-lints.tsv"

# shellcheck source=bin/lib/mc-prequeue.sh
. "$DIR/bin/lib/mc-prequeue.sh" || { echo "FAIL: cannot source bin/lib/mc-prequeue.sh"; exit 1; }

# Not root: the snapshot lib cannot switch to nobody, so run as this user.
NONROOT_SNAPSHOT='
rp_snapshot_probe() { return 0; }
rp_snapshot_reachable() { [ -d "$1" ]; }
chown() { [ "$(id -u)" = 0 ] && command chown "$@"; return 0; }
rp_snapshot_run() {
  local dir="$1" w; shift; w=$(dirname "$dir")
  ( cd "$dir" 2>/dev/null || exit 125
    env -i PATH="$PATH" HOME="$w/home" TMPDIR="$w/tmp" LANG=C.UTF-8 LC_ALL=C.UTF-8 HARNESS_TEST_SANDBOX=1 \
      RATCHET_BASE="${RATCHET_BASE:-origin/main}" TI_BASE="${TI_BASE:-origin/main}" "$@" )
}'
if [ "$(id -u)" != 0 ]; then
  . "$DIR/bin/lib/rules-pack-snapshot.sh" || exit 1
  eval "$NONROOT_SNAPSHOT"
fi

# ── stubs: the conductor helpers pq_gate and the hook read ──
mc_rest_var() { echo tip >> "$TIPS"; printf -v "$1" '{"sha":"%s"}' "$MAINSHA"; }
gh_rest() { echo "gh_rest $*" >> "$CALLS"; return 97; }
mc_log() { echo "$*" >> "$LOG"; }
mc_attempt_has() { grep -qxF "$1" "$ATT" 2>/dev/null; }
mc_attempt_put() { echo "$1" >> "$ATT"; }
mc_alert() { echo "alert $*" >> "$LOG"; }
mc_git_locked() { echo "lock wait=${MC_GIT_LOCK_WAIT:-unset}" >> "$LOCKS"; shift; [ -e "$T/lock-busy" ] && return 99; "$@"; }
mc_funnel_repo() { MC_REMOTE="$O"; MC_FUNNEL_WT="$CL"; return 0; }
mc_git_auth_clear() { return 0; }
# mc_merge_tree_fetch's contract (bin/lib/mc/rebase.sh): origin/main and the
# head in the clone, rc 1 and a reason when the head cannot be had.
mc_merge_tree_fetch() {
  git -C "$1" -c credential.helper= fetch -q --no-tags "$2" '+refs/heads/main:refs/remotes/origin/main' '+refs/heads/*:refs/remotes/origin/*' >/dev/null 2>&1 \
    || { printf 'origin/main could not be fetched'; return 1; }
  git -C "$1" cat-file -e "$3^{commit}" 2>/dev/null || { printf 'the head is not in the clone'; return 1; }
}
lane_knob() {
  case "$2" in
    MC_SCHEMA_RESTAMP|MC_MIGRATION_RECHECK) printf 0 ;;
    MC_PREQUEUE_GATE) printf '%s' "${GATE:-0}" ;;
    MC_PREQUEUE_FAST_LINTS) printf '%s' "${FL_KNOB:-}" ;;
    MC_PREQUEUE_FAST_LINTS_SET) printf '%s' "${FL_SET:-}" ;;
    MC_PREQUEUE_FAST_LINTS_BUDGET_S) printf '%s' "${FL_BUDGET:-}" ;;
    MC_PREQUEUE_FAST_LINTS_RESERVE_S) printf '%s' "${FL_RESERVE:-}" ;;
  esac; return 0
}
pq_resolve() { echo "$*" >> "$RESOLVES"; }
pq_status_gate() { :; }

# seed — main M0 holds tests/x-test.sh (red when bad.txt exists) and
# conflict.txt; heads cut from M0: HCLEAN adds headfile.txt, HRED adds bad.txt
# and headfile.txt, HCONF changes conflict.txt. Main then moves to M1, which
# adds mainfile.txt and changes conflict.txt the other way.
seed() {
  scratch_rm "$O" 2>/dev/null; scratch_rm "$W" 2>/dev/null; scratch_rm "$CL" 2>/dev/null
  git init -q --bare "$O"; mkdir -p "$W/tests"; git -C "$W" init -q
  printf '#!/bin/bash\n[ ! -f bad.txt ]\n' > "$W/tests/x-test.sh"; echo one > "$W/conflict.txt"
  git -C "$W" add -A; git -C "$W" commit -qm M0; M0=$(git -C "$W" rev-parse HEAD)
  git -C "$W" checkout -qb clean; echo h > "$W/headfile.txt"; git -C "$W" add -A; git -C "$W" commit -qm clean; HCLEAN=$(git -C "$W" rev-parse HEAD)
  git -C "$W" checkout -qb red "$M0"; echo h > "$W/headfile.txt"; echo b > "$W/bad.txt"; git -C "$W" add -A; git -C "$W" commit -qm red; HRED=$(git -C "$W" rev-parse HEAD)
  git -C "$W" checkout -qb conf "$M0"; echo head > "$W/conflict.txt"; git -C "$W" commit -qam conf; HCONF=$(git -C "$W" rev-parse HEAD)
  git -C "$W" checkout -q main; echo m > "$W/mainfile.txt"; echo main > "$W/conflict.txt"; git -C "$W" add -A; git -C "$W" commit -qm M1
  MAINSHA=$(git -C "$W" rev-parse HEAD)
  git -C "$W" push -q "$O" main clean red conf || bad "setup: push to the local origin failed"
  git clone -q "$GHURL" "$CL" || bad "setup: clone failed"
  : > "$LOG"; : > "$ATT"; : > "$LOCKS"; : > "$TIPS"; : > "$RESOLVES"
  scratch_rm "$MC_STATE_DIR" 2>/dev/null; rm -f "$T/lock-busy" "$T/enqueued"
  export ACTIONS=1 P=proj KEY="$SLUG#$NUM"
  unset FL_KNOB FL_BUDGET FL_RESERVE; FL_SET=lint; GATE=0
}
# fl <head> [<left_s>] — the hook alone, its last line.
fl() { WORD=$(pq_fastlint "$SLUG" "$NUM" "https://github.com/$SLUG/pull/$NUM" "$1" "$MAINSHA" ${2:+"$2"} 2>/dev/null | tail -n1); }
gate() { pq_gate "$SLUG" "$NUM" "https://github.com/$SLUG/pull/$NUM" "$1" main > "$T/word"; GWORD=$(cat "$T/word"); }
# ready_arm — the READY arm's shape: enqueue only on proceed.
ready_arm() { gate "$1"; [ "$GWORD" = proceed ] && echo "$SLUG#$NUM" >> "$T/enqueued"; return 0; }
left_dirs() { find "$MC_H/tmp/prequeue-fast" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l; }

# ════════════════════════ Part 1: the hook and pq_gate ════════════════════════
seed

# ── H4 / H5: wanted ──
if declare -F pq_fastlint_wanted >/dev/null; then
  pq_fastlint_wanted && ok || bad "H4 the knob's default (1) with ACTIONS=1 must be wanted"
  FL_KNOB=0; pq_fastlint_wanted && bad "H4 MC_PREQUEUE_FAST_LINTS=0 must not be wanted" || ok; unset FL_KNOB
  ACTIONS=0; pq_fastlint_wanted && bad "H5 ACTIONS=0 must not be wanted" || ok; ACTIONS=1
else
  bad "H4 pq_fastlint_wanted is not defined (bin/lib/mc-prequeue.d/fast-lints.sh)"
fi

# ── H2: a clean head is green ──
if declare -F pq_fastlint >/dev/null; then
  fl "$HCLEAN"
  [ "$WORD" = green ] && ok || bad "H2 a clean head must answer green, got '$WORD' (log: $(cat "$LOG"))"
  grep -q "^$SLUG#$NUM PREQUEUE_FAST_LINT green head=${HCLEAN:0:12} main=${MAINSHA:0:12} s=[0-9]* red=none " "$LOG" \
    && ok || bad "H2 one PREQUEUE_FAST_LINT green line (log: $(cat "$LOG"))"
  grep -qx 'lock wait=5' "$LOCKS" && ok || bad "H2 the prepare runs under the git lock with the gate's 5 s wait (got: $(cat "$LOCKS"))"
  [ "$(left_dirs)" = 0 ] && ok || bad "H7 green left a work dir: $(ls "$MC_H/tmp/prequeue-fast")"

  # ── H3: a red item ──
  fl "$HRED"
  [ "$WORD" = "red tests/x-test.sh" ] && ok || bad "H3 a red item must answer 'red tests/x-test.sh', got '$WORD' (log: $(cat "$LOG"))"
  grep -q "PREQUEUE_FAST_LINT red head=${HRED:0:12} .* red=lint " "$LOG" && ok || bad "H3 the red line names the item (log: $(cat "$LOG"))"
  [ "$(left_dirs)" = 0 ] && ok || bad "H7 red left a work dir"

  # ── H1: the merged tree holds both sides ──
  FL_SET=mainside,headside; fl "$HCLEAN"
  [ "$WORD" = "red tests/headside-test.sh" ] && ok \
    || bad "H1 the merged tree must hold main's mainfile.txt and the head's headfile.txt (want 'red tests/headside-test.sh', got '$WORD')"
  FL_SET=lint

  # ── K2: the settings row limits the run ──
  FL_SET=mainside; fl "$HRED"
  [ "$WORD" = green ] && ok || bad "K2 a set without lint must not run lint, got '$WORD'"
  FL_SET=lint,mainside; fl "$HRED"
  [ "$WORD" = "red tests/x-test.sh" ] && ok || bad "K2 a set with lint runs it, got '$WORD'"
  FL_SET="nope,lint"; fl "$HRED"
  [ "$WORD" = "red tests/x-test.sh" ] && ok || bad "K2 an unknown id in the row is skipped, got '$WORD'"
  FL_SET=lint

  # ── C1: the main baseline is cached per (main, id) ──
  [ "$(cat "$MC_STATE_DIR/prequeue/fastlint-main/$MAINSHA.lint" 2>/dev/null)" = 0 ] && ok \
    || bad "C1 the base run's rc is cached at prequeue/fastlint-main/<main>.lint (got: $(ls "$MC_STATE_DIR/prequeue/fastlint-main" 2>&1))"
  echo 1 > "$MC_STATE_DIR/prequeue/fastlint-main/$MAINSHA.lint"
  fl "$HRED"
  [ "$WORD" = green ] && grep -q "PREQUEUE_FAST_LINT green .*preexisting=lint " "$LOG" && ok \
    || bad "C1 a cached red baseline makes the item preexisting, got '$WORD'"
  echo 0 > "$MC_STATE_DIR/prequeue/fastlint-main/$MAINSHA.lint"

  # ── K3: the reserve kept back from the gate's call budget is a knob ──
  # 15 s left: the default reserve (10 s) leaves 5 s and the set runs; a
  # reserve of 20 s from the settings row leaves none, so the hook does not run.
  fl "$HCLEAN" 15
  [ "$WORD" = green ] && ok || bad "K3 15 s left and the default 10 s reserve must run the set, got '$WORD'"
  FL_RESERVE=20; fl "$HCLEAN" 15
  case "$WORD" in "none could-not-run"*) ok ;; *) bad "K3 MC_PREQUEUE_FAST_LINTS_RESERVE_S=20 with 15 s left must answer could-not-run, got '$WORD'" ;; esac
  unset FL_RESERVE

  # ── H6: a conflict ──
  fl "$HCONF"
  [ "$WORD" = "none conflict" ] && ok || bad "H6 a conflict must answer 'none conflict', got '$WORD'"
  [ "$(left_dirs)" = 0 ] && ok || bad "H7 a conflict left a work dir"

  # ── H8: the git lock is busy ──
  touch "$T/lock-busy"; fl "$HRED"; rm -f "$T/lock-busy"
  [ "$WORD" = "none lock-busy" ] && ok || bad "H8 a busy lock must answer 'none lock-busy', got '$WORD'"
  [ "$(left_dirs)" = 0 ] && ok || bad "H7 a busy lock left a work dir"
else
  bad "H2 pq_fastlint is not defined (bin/lib/mc-prequeue.d/fast-lints.sh)"
fi

# ── G7: the REPRO. Gate off, a red head: pq_gate parks it ──
seed
ready_arm "$HRED"
[ "$GWORD" = red ] && [ "$PQ_VERDICT" = red ] && ok || bad "G7 MC_PREQUEUE_GATE=0 and a red fast lint: pq_gate must answer red, got '$GWORD'"
[ "$PQ_SUITES" = tests/x-test.sh ] && ok || bad "G7 PQ_SUITES must name tests/x-test.sh, got '$PQ_SUITES'"
[ -z "$PQ_PATH" ] && ok || bad "G7 PQ_PATH stays empty, got '$PQ_PATH'"
[ "$PQ_MAIN" = "$MAINSHA" ] && ok || bad "G7 PQ_MAIN is the main tip, got '$PQ_MAIN'"
[ ! -e "$T/enqueued" ] && ok || bad "G7 a red head must never be enqueued"

# ── G1: gate off, a clean head proceeds and is enqueued ──
seed
ready_arm "$HCLEAN"
[ "$GWORD" = proceed ] && [ -s "$T/enqueued" ] && ok || bad "G1 a clean head must proceed and be enqueued, got '$GWORD' (log: $(cat "$LOG"))"
grep -q 'PREQUEUE_FAST_LINT green' "$LOG" && ok || bad "G1 the fast lint ran with the gate off (log: $(cat "$LOG"))"

# ── G5: gate off, fast lint knob 0, no other hook: no main-tip read ──
seed; FL_KNOB=0
gate "$HRED"
[ "$GWORD" = proceed ] && ok || bad "G5 knob 0 must proceed, got '$GWORD'"
[ ! -s "$TIPS" ] && ok || bad "G5 knob 0 with the gate off must read no main tip (BH-8062 pin), got $(grep -c . "$TIPS") read(s)"
grep -q PREQUEUE_FAST_LINT "$LOG" && bad "G5 knob 0 must not run the hook" || ok

# ── G6: gate on, the fast lint red wins before the cache read ──
seed; GATE=1
gate "$HRED"
[ "$GWORD" = red ] && [ "$PQ_SUITES" = tests/x-test.sh ] && ok || bad "G6 gate on: red with tests/x-test.sh, got '$GWORD' '$PQ_SUITES'"
[ ! -s "$RESOLVES" ] && ok || bad "G6 the fast lint red must answer before pq_resolve (got: $(cat "$RESOLVES"))"
[ -z "$(ls "$MC_STATE_DIR/prequeue/" 2>/dev/null | grep -v '^fastlint-main$')" ] && ok || bad "G6 a fast lint red writes no prequeue verdict file"

# ── K1: code defaults equal the registry defaults ──
for n in MC_PREQUEUE_FAST_LINTS MC_PREQUEUE_FAST_LINTS_BUDGET_S MC_PREQUEUE_FAST_LINTS_JOBS MC_PREQUEUE_FAST_LINTS_RESERVE_S; do
  f="$DIR/catalog/lanes.d/merge-conductor.knobs.d/$n.json"
  d=$(jq -r '.default' "$f" 2>/dev/null)
  c=""; for kv in $PQ_KNOB_DEFAULTS; do [ "${kv%%=*}" = "$n" ] && c="${kv#*=}"; done
  [ -n "$d" ] && [ "$d" = "$c" ] && ok || bad "K1 $n: registry default '$d' vs PQ_KNOB_DEFAULTS '$c'"
done
[ "$(jq -r '.default' "$DIR/catalog/lanes.d/merge-conductor.knobs.d/MC_PREQUEUE_FAST_LINTS_SET.json" 2>/dev/null)" = "" ] \
  && [ "$(jq -r '.type' "$DIR/catalog/lanes.d/merge-conductor.knobs.d/MC_PREQUEUE_FAST_LINTS_SET.json" 2>/dev/null)" = string ] \
  && ok || bad "K1 MC_PREQUEUE_FAST_LINTS_SET is a string knob with an empty default"

# ════════════════ Part 2: bin/merge-conductor.sh WHOLE, this repo's tree ════════════════
# shellcheck source=tests/lib/gh-list-bridge.sh
. "$DIR/tests/lib/gh-list-bridge.sh" || exit 1
# shellcheck source=tests/lib/verdict-fixture.sh
. "$DIR/tests/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
CSLUG=example-org/demo-os; U="https://github.com/$CSLUG/pull"; CNUM=41
git config --global "url.$T/corigin.git.insteadOf" "https://x-access-token@github.com/$CSLUG.git"
git config --global "url.$T/corigin.git.insteadOf" "https://github.com/$CSLUG.git" --add
# main M0 = this checkout's files (tracked and new, not ignored); HPROSE adds a
# knob whose zero_means is prose; HOK adds a note; main M1 = M0 + one file.
S="$T/cseed"; mkdir -p "$S"
( cd "$DIR" && git ls-files -co --exclude-standard -z | tar --null -T - -cf - 2>/dev/null ) | tar -C "$S" -xf - \
  || bad "setup: could not copy the tree"
git -C "$S" init -q; git -C "$S" add -A; git -C "$S" commit -qm M0; CM0=$(git -C "$S" rev-parse HEAD)
git -C "$S" checkout -qb prose
jq '.zero_means = "only when the queue is empty"' "$S/catalog/lanes.d/merge-conductor.knobs.d/MC_PREQUEUE_TRACE.json" > "$S/k.json" \
  && mv "$S/k.json" "$S/catalog/lanes.d/merge-conductor.knobs.d/MC_PREQUEUE_TRACE.json"
git -C "$S" commit -qam prose; HPROSE=$(git -C "$S" rev-parse HEAD)
git -C "$S" checkout -qb ok "$CM0"; echo fixture > "$S/docs/bh8473-fixture.txt"; git -C "$S" add -A; git -C "$S" commit -qm ok; HOK=$(git -C "$S" rev-parse HEAD)
git -C "$S" checkout -q main 2>/dev/null || git -C "$S" checkout -q master
echo main-moved > "$S/docs/bh8473-main.txt"; git -C "$S" add -A; git -C "$S" commit -qm M1; CM1=$(git -C "$S" rev-parse HEAD)
git init -q --bare "$T/corigin.git"
git -C "$S" push -q "$T/corigin.git" "$CM1:refs/heads/main" "$HPROSE:refs/pull/41/head" "$HOK:refs/pull/42/head" || bad "setup: push failed"

# the scratch harness: the conductor's whole closure, two libs stubbed
export HARNESS="$T/ch"
mkdir -p "$T/ch/bin/lib" "$T/ch/logs" "$T/ch/state" "$T/ch/flags" "$T/ch/locks" "$T/ch/builds" "$T/ch/env" "$T/ch/tmp" "$T/ch/catalog" "$T/cfakebin" "$T/repos"
chmod 711 "$T/ch" "$T/ch/tmp"
cat > "$T/ch/bin/lib/ticket-ownership.sh" <<'EOF'
to_lane_hold() { return 1; }
to_lane_lead_fence() { TO_LEAD_CLEARED=0; return 1; }
to_lead_merge_hold() { return 1; }
EOF
cat > "$T/ch/bin/lib/block-gate.sh" <<'EOF'
bg_enforce() { return 1; }
bg_scan_read() { return 0; }
bg_scan() { return 0; }
bg_why() { :; }
bg_reason() { :; }
bg_refuse() { return 0; }
EOF
: > "$T/ch/bin/lib/pr-snapshot.sh"
scratch_install_closure bin/merge-conductor.sh "$T/ch" >/dev/null || exit 1
scratch_install_closure bin/jobs-client.sh "$T/ch" >/dev/null || exit 1
scratch_install_closure bin/prequeue-fast-lints.sh "$T/ch" >/dev/null || exit 1
cp "$CATALOG" "$T/ch/catalog/prequeue-fast-lints.tsv" 2>/dev/null || bad "setup: no catalog to install"
scratch_rm "$T/ch/bin/lib/gh-limit-logger.sh"
[ "$(id -u)" != 0 ] && printf '%s\n' "$NONROOT_SNAPSHOT" >> "$T/ch/bin/lib/rules-pack-snapshot.sh"
cp "$DIR/bin/fleet-conf.sh" "$T/ch/bin/" || exit 1
cp "$DIR/tests/lib/rest-emit.sh" "$T/cfakebin/restpr" && chmod +x "$T/cfakebin/restpr" || exit 1
for s in agent-call beat deploy-request pre-arm-guards codegraph-ensure; do printf '#!/bin/bash\nexit 0\n' > "$T/ch/bin/$s.sh"; chmod +x "$T/ch/bin/$s.sh"; done
printf '#!/bin/bash\necho "[lane-alert] $*" >> "%s/ch/logs/ALERTS.log"\n' "$T" > "$T/ch/bin/lane-alert.sh"; chmod +x "$T/ch/bin/lane-alert.sh"
printf 'demo %s - - 2 box-demo\n' "$CSLUG" > "$T/ch/fleet.conf"
: > "$T/ch/env/global.env"
REC="$T/ch/builds/pool-demo-BH-20-202610260001"; mkdir -p "$REC"
MGFY_YML=$(printf 'queue_rules:\n  - name: default\n    merge_method: squash\n' | base64 | tr -d '\n')
MCD="$T/ch/state/merge-conductor"
# The stub gh: main is $T/cmain, the PR head is $T/chead. An enqueue write goes
# to $T/c-enq.txt; the gate's own calls are only the main-tip read.
cat > "$T/cfakebin/gh" <<EOF
#!/bin/bash
N=$CNUM; HD=\$(cat "$T/chead"); MN=\$(cat "$T/cmain")
case "\$*" in
  *"auth token"*) echo faketoken-fixture ;;
  *"api rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  "workflow run prequeue-gate.yml"*) printf '%s\n' "\$*" >> "$T/c-dispatch.txt"; exit 0 ;;
  *"api -i -X GET repos/$CSLUG/commits/main"|*"api -i -X GET repos/$CSLUG/commits/main "*) restpr --raw 200 "{\"sha\":\"\$MN\"}" ;;
  *"api -i -X GET repos/$CSLUG/rulesets"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/$CSLUG/contents/.mergify.yml"*) restpr --raw 200 '{"content":"$MGFY_YML"}' ;;
  *"actions/runs?head_sha="*) restpr --raw 200 '{"workflow_runs":[{"id":1,"name":"CI","status":"completed","conclusion":"success","run_started_at":"2026-10-26T01:00:00Z"}]}' ;;
  *"check-runs?check_name="*) restpr --raw 200 '{"check_runs":[{"name":"Build + Unit tests","status":"completed","conclusion":"success","started_at":"2026-10-26T01:00:00Z"}]}' ;;
  *"api -i -X GET repos/"*"/commits/"*"/check-runs"*) restpr --raw 200 '{"total_count":1,"check_runs":[{"name":"Build + Unit tests","status":"completed","conclusion":"success","started_at":"2026-10-26T01:00:00Z"}]}' ;;
  *"api -i -X POST repos/$CSLUG/issues/\$N/comments -f body=@mergifyio"*) printf '%s\n' "\$*" >> "$T/c-enq.txt"; restpr --raw 201 '{"id":901}' ;;
  *"/issues/"*"/labels"*) printf '%s\n' "\$*" >> "$T/c-enq.txt" ;;
  *"api -X POST repos/"*"/issues/"*"/comments"*) case "\$*" in *mergifyio*) printf '%s\n' "\$*" >> "$T/c-enq.txt" ;; esac ;;
  *"pr merge"*) printf '%s\n' "\$*" >> "$T/c-enq.txt"; exit 0 ;;
  *"/pulls/"*"/merge"|*"/pulls/"*"/merge "*) printf '%s\n' "\$*" >> "$T/c-enq.txt"; restpr --raw 200 '{"merged":true}' ;;
  *"api -i -X POST repos/"*"/issues/"*"/comments"*) restpr --raw 201 '{"id":1}' ;;
  *"api -i -X GET repos/"*"/issues/"*"/comments"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/"*"/pulls -f state="*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/$CSLUG/pulls/\$N"*"v3.diff"*) restpr --diff ;;
  *"api -i -X GET repos/"*"/pulls/"*"/files"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/$CSLUG/pulls/\$N"*) restpr OPEN "\$HD" ticket/bh-20 main "" MERGEABLE CLEAN operator "" "Closes #20" ;;
  *"api repos/$CSLUG -q .id"*) echo 1 ;;
  *"pr list -R $CSLUG --state open"*)
    printf '[{"number":%s,"url":"$U/%s","headRefOid":"%s","headRefName":"ticket/bh-20","baseRefName":"main","isDraft":false,"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","state":"OPEN","isInMergeQueue":false,"labels":[]}]\n' "\$N" "\$N" "\$HD" ;;
  *"pr list"*"--state closed"*) : ;;
esac
exit 0
EOF
chmod +x "$T/cfakebin/gh"
cat > "$T/cfakebin/curl" <<EOF
#!/bin/bash
URL="\${!#}"; M=GET
while [ \$# -gt 0 ]; do case "\$1" in -X) M="\$2"; shift 2 ;; *) shift ;; esac; done
case "\$M \$URL" in
  "PUT "*) printf '{"ok":true}\n200\n' ;;
  "GET "*/api/verdicts\?*) printf '{"standing":null}\n200\n' ;;
  *) printf '{"error":"not found"}\n404\n' ;;
esac
EOF
chmod +x "$T/cfakebin/curl"
MCLOG="$T/ch/logs/merge-conductor.log"; ROWS="$MCD/pr-state.tsv"
# creset <head> — #41 approved and green at <head>, main M1, a fresh conductor
# state. KEEP=1 keeps the state and the log (a second tick).
creset() {
  if [ "${KEEP:-0}" != 1 ]; then
    scratch_rm "$MCD"; scratch_rm "$T/ch/state/tier2-autoenqueue.txt"
    rm -f "$T/ch/logs/"*.log; mkdir -p "$MCD"; : > "$ROWS"
  fi
  : > "$T/c-enq.txt"; : > "$T/c-dispatch.txt"
  echo "$1" > "$T/chead"; echo "$CM1" > "$T/cmain"
  echo "PR_CREATED $U/$CNUM" > "$REC/RESULT"; printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$REC/review.md"
  echo "$1" > "$REC/reviewed-sha"; : > "$REC/pipeline.log"
  touch "$T/ch/flags/merge-conductor-actions" "$T/ch/flags/merge-conductor-merge"
}
ctick() {
  ( cd "$T" && env PATH="$T/cfakebin:$PATH" HARNESS="$T/ch" FLEET_CONF="$T/ch/fleet.conf" HARNESS_SECRET=x JOBS_URL=http://worker.test GH_TOKEN=pat-default-fixture \
    MC_REPOS="$T/repos" MC_MERGE_BUDGET=5 MC_ENQUEUE_SETTLE=0 MC_MERGE_SETTLE=0 MC_MERGIFY_SETTLE=0 MC_MERGIFY_WAIT_S=0 MC_QUEUE_TTL=0 \
    MC_MAIN_RED_DETECT=0 MC_DETACHED_REBASE=0 PR_DEP_GATE_TICKET=0 MC_STEP_TIMEOUT_S=600 \
    MC_PREQUEUE_GATE=0 MC_SCHEMA_RESTAMP=0 MC_MIGRATION_RECHECK=0 MC_PREQUEUE_FAST_LINTS_SET=lanes-registry \
    bash "$T/ch/bin/merge-conductor.sh" >/dev/null 2>"$T/ctick.err" ) || { echo "tick rc=$? stderr:"; tail -5 "$T/ctick.err"; }
  [ -s "$ROWS" ] || { echo "tick wrote no row; stderr:"; tail -5 "$T/ctick.err"; tail -5 "$MCLOG" 2>/dev/null; }
}
CK="$CSLUG#$CNUM"
cstate()  { awk -F'\t' -v k="$CK" '$1==k {print $2}' "$ROWS"; }
creason() { awk -F'\t' -v k="$CK" '$1==k {print $7}' "$ROWS"; }
cenq()    { grep -c "issues/$CNUM/comments\|issues/$CNUM/labels\|pulls/$CNUM/merge\|pr merge $U/$CNUM" "$T/c-enq.txt" 2>/dev/null || true; }
clog()    { grep -F "$CK" "$MCLOG" 2>/dev/null | grep -i 'prequeue\|fast_lint' | tail -"${1:-6}"; }

# ── A1 / G2: a prose zero_means parks the row with lanes-registry named ──
creset "$HPROSE"; ctick
[ "$(cstate)" = BLOCKED_HUMAN ] && ok || bad "A1 the prose zero_means head must park BLOCKED_HUMAN, state '$(cstate)' (log: $(clog))"
case "$(creason)" in
  "prequeue-red: tests/lanes-registry-test.sh on main ${CM1:0:12} — "*) ok ;;
  *) bad "A1 the park names tests/lanes-registry-test.sh and main ${CM1:0:12}, got '$(creason)'" ;;
esac
[ "$(cenq)" = 0 ] && ok || bad "A1 a red head is never enqueued (argv: $(cat "$T/c-enq.txt"))"
[ ! -s "$T/c-dispatch.txt" ] && ok || bad "A1 the gate is off: no prequeue-gate.yml dispatch"
grep -q "$CK PREQUEUE_FAST_LINT red head=${HPROSE:0:12} main=${CM1:0:12} .*red=lanes-registry " "$MCLOG" 2>/dev/null \
  && ok || bad "A1 one PREQUEUE_FAST_LINT red line naming lanes-registry (log: $(clog))"

# ── G3: the resolver's brief reads the park ──
awk '/^br_prequeue_brief\(\)/ {p=1} p{print} p&&/^}$/{exit}' "$DIR/bin/blocked-resolver.sh" > "$T/brief.sh"
BRIEF=$( . "$T/brief.sh" && br_prequeue_brief "$(creason)" )
grep -q "fail when this head is merged onto current main ${CM1:0:12}: tests/lanes-registry-test.sh\." <<<"$BRIEF" \
  && ok || bad "G3 br_prequeue_brief names the suite and the main sha (got: $BRIEF)"

# ── G4: a second tick on the same head and main: one PREQUEUE_RED line ──
KEEP=1 creset "$HPROSE"; ctick
[ "$(grep -c "$CK PREQUEUE_RED on ${HPROSE:0:8}" "$MCLOG" 2>/dev/null)" = 1 ] && ok \
  || bad "G4 exactly one PREQUEUE_RED line over two ticks (got $(grep -c "PREQUEUE_RED" "$MCLOG" 2>/dev/null))"
[ "$(cstate)" = BLOCKED_HUMAN ] && [ "$(cenq)" = 0 ] && ok || bad "G4 still parked, never enqueued (state '$(cstate)')"

# ── A2: a clean head on the same main is enqueued ──
creset "$HOK"; ctick
[ "$(cenq)" -ge 1 ] && ok || bad "A2 a clean head must be enqueued (state '$(cstate)', reason '$(creason)'; log: $(clog))"
[ "$(cstate)" != BLOCKED_HUMAN ] && ok || bad "A2 a clean head must not park (reason '$(creason)')"
grep -q "$CK PREQUEUE_FAST_LINT green head=${HOK:0:12} " "$MCLOG" 2>/dev/null && ok || bad "A2 one PREQUEUE_FAST_LINT green line (log: $(clog))"
[ -z "$(find "$T/ch/tmp/prequeue-fast" -mindepth 1 -maxdepth 1 2>/dev/null)" ] && ok || bad "H7 the conductor ticks left a work dir"

# ── H9: no vendor call in the whole suite ──
[ ! -s "$CALLS" ] && ok || bad "H9 the suite made GitHub or Mergify calls: $(head -5 "$CALLS")"

echo "mc-prequeue-fast-lints: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
