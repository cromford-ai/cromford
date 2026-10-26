#!/bin/bash
# tests/main-red-direct-revert.bh-6747-test.sh — BH-6747 (BH-6541.4): a red main
# that is one first-parent merge past the last green is reverted without a
# probe or a bisect, and the BH-6502 re-check logs FREEZE_LIFTED when it lifts.
#
# THREE PARTS, each with its own scratch world under $T:
#   DRIVER  the REAL bin/main-red-bisect.sh, its lib closure installed with
#           scratch_install_closure, the contract functions replaced by the
#           MAIN_RED_BISECT_FIXTURE recorders (the BH-3685 driver suite's
#           scaffold), over a scratch repo built per case:
#     R1  one `Merge pull request #101` merge -> no probe, one act, the acted
#         episode has culprit/pr/steps=0/shortcut=one-merge and no bisect= key,
#         ledger row culprit, no pending file
#     R1c the same span, still-red rc 1 -> no act, row stale, no probe
#     R2  two PR merges -> P0 and P1 probe, mrb_bisect gets MAX_STEPS-2, no
#         shortcut= key
#     R2b one merge whose subject is `Merge branch 'x'` -> probes run, no act
#     R2c one PR merge plus one plain commit on the first parent -> probes run,
#         the bisect's culprit is acted on, no shortcut= key
#     R2d green == red (no merge at all) -> probes run, today's flake row
#   ACT     the REAL mrb_act_culprit over the episode R1's driver handed the act
#           (the BH-3685 act suite's scaffold: gh and curl recorders on PATH, a
#           bare remote), so the shortcut key round-trips writer -> reader:
#     R1b one pulls POST, labels ["fix-main-red","hotfix"], one re-land issue
#     R3  the PR body names the red suites
#     R3b the PR body and the re-land body carry the one-merge wording; the
#         same episode without shortcut= keeps today's bisect first line
#     R5  the warn alert names #101, the suites, the revert PR, the re-land
#         ticket and `no bisect`
#   RECHECK the REAL bin/main-red-recheck.sh and bin/main-red-detector.sh (the
#           BH-6502 suite's scaffold, stubbed gh pages):
#     R4  a green flagged repo, since= 90 min ago -> flag gone, one
#         `FREEZE_LIFTED after=90 flag=main-red-o-r` line
#     R4b still red on the same sha -> flag stays, no FREEZE_LIFTED line
#     R4c no freeze up -> no detector start, no FREEZE_LIFTED line, rc 0
#     R4d raised= wins over since=; R4e no key -> the file mtime; R4f a start
#         in the future -> after=0
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/main-red-direct-revert.bh-6747-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
REPO_ROOT="$DIR"
. "$(dirname "$0")/lib/rendered.sh" || exit 1

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
check() { if eval "$2"; then ok; else bad "$1"; fi; }
command -v jq >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1 && command -v flock >/dev/null 2>&1 || {
  echo "main-red-direct-revert.bh-6747-test: SKIPPED — jq/python3/flock is not installed"; exit 0; }
cnt() { # cnt <file> <ERE> -> matching line count (0 for a missing file)
  local n; n=$(grep -cE -- "$2" "$1" 2>/dev/null); printf '%s' "${n:-0}"
}
epget() { awk -F= -v k="$2" '$1==k {v=substr($0, length(k)+2)} END {print v}' "$1" 2>/dev/null; }

export GIT_AUTHOR_DATE="2026-09-30T12:00:00Z" GIT_COMMITTER_DATE="2026-09-30T12:00:00Z"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export GIT_CONFIG_NOSYSTEM=1

# ════════════════════════════ DRIVER ════════════════════════════════════════
D1="$T/drv"
H="$D1/h"
mkdir -p "$H/bin/lib" "$H/state" "$H/flags" "$H/logs" "$H/catalog"
# The stubs first: scratch_install_closure skips a file that is already there.
cat > "$H/bin/jobs-client.sh" <<SH
#!/bin/bash
[ "\${BASH_SOURCE[0]}" = "\$0" ] || return 0
echo "\$*" >> "$D1/ledger.calls"
case "\${1:-}" in
  ledger-get)
    s=\$(awk -v k="\$2" -v y="\$3" '\$1==k && \$2==y {s=\$3} END {print s}' "$D1/ledger" 2>/dev/null)
    [ -n "\$s" ] && { printf '%s' "\$s"; exit 0; }
    exit 2 ;;
  ledger-put) echo "\$2 \$3 \$4" >> "$D1/ledger"; exit 0 ;;
esac
exit 0
SH
printf '#!/bin/bash\necho "$*" >> "%s/alerts"\n' "$D1" > "$H/bin/lane-alert.sh"
chmod +x "$H/bin/jobs-client.sh" "$H/bin/lane-alert.sh"
( cd "$REPO_ROOT" && scratch_install_closure bin/main-red-bisect.sh "$H" ) >/dev/null \
  || bad "setup: driver closure install failed"
LANE="$H/bin/main-red-bisect.sh"

cat > "$D1/fakes.sh" <<SH
F="$D1"
mrb_detect_episodes() { echo "detect \$*" >> "\$F/calls"; cp "\$F"/ep-src/* "\$3"/ 2>/dev/null; return 0; }
mrb_probe() {
  echo "probe \$2 \$(tr '\n' ' ' < "\$3")" >> "\$F/calls"
  cat "\$F/answers/\$2" 2>/dev/null || echo red
}
mrb_bisect() {
  local fn="\$1" budget="\$2"; shift 2
  local c=("\$@") i=\$((\$# - 1)) n=0
  echo "bisect budget=\$budget n=\$#" >> "\$F/calls"
  while [ "\$n" -lt "\$budget" ] && [ "\$i" -ge 0 ]; do
    "\$fn" "\${c[\$i]}" >/dev/null; n=\$((n+1)); i=\$((i-1))
  done
  echo "found \$(cat "\$F/bisect-found") \$n"
}
mrb_episode_still_red() {
  echo "still_red \$1" >> "\$F/calls"
  return "\$(cat "\$F/stale-rc" 2>/dev/null || echo 0)"
}
_fake_act() {
  local n
  n=\$(( \$(cat "\$F/actn" 2>/dev/null || echo 0) + 1 )); echo "\$n" > "\$F/actn"
  echo "act_\$1 \$2" >> "\$F/calls"
  cp "\$2" "\$F/acted.\$n"
  return 0
}
mrb_act_culprit()  { _fake_act culprit "\$1"; }
mrb_act_notmerge() { _fake_act notmerge "\$1"; }
SH

R="$D1/repos/cromford"
SLUG=example-org/cromford
pr_merge() { # pr_merge <n> — one `git merge --no-ff` PR merge onto main; sets M<n>
  git -C "$R" checkout -q -b "ticket/bh-$1" main
  echo "$1" > "$R/f.$1"; git -C "$R" add "f.$1"; git -C "$R" commit -q -m "work on bh-$1"
  git -C "$R" checkout -q main
  git -C "$R" merge -q --no-ff "ticket/bh-$1" -m "Merge pull request #$1 from example-org/ticket/bh-$1" -m "BH-$1: title for bh-$1"
  eval "M$1=$(git -C "$R" rev-parse HEAD)"
}
world() { # world <one|two|branch|plain|none> — a fresh repo, ledger, recorders, episode
  scratch_rm "$D1/repos"; scratch_rm "$D1/answers"; scratch_rm "$D1/ep-src"; scratch_rm "$H/state/main-red-bisect"
  rm -f "$D1/calls" "$D1/alerts" "$D1/ledger" "$D1/ledger.calls" "$D1/stale-rc" "$D1/actn" "$D1"/acted.* \
    "$D1/bisect-found" "$H/logs/main-red-bisect.log"
  mkdir -p "$R" "$D1/answers" "$D1/ep-src"
  echo local > "$H/state/box-name"
  git -C "$R" init -q -b main
  echo base > "$R/f"; git -C "$R" add f; git -C "$R" commit -q -m init
  GREEN=$(git -C "$R" rev-parse HEAD)
  case "$1" in
    one)    pr_merge 101 ;;
    two)    pr_merge 101; pr_merge 102 ;;
    branch) git -C "$R" checkout -q -b x main; echo x > "$R/x"; git -C "$R" add x; git -C "$R" commit -q -m x
            git -C "$R" checkout -q main; git -C "$R" merge -q --no-ff x -m "Merge branch 'x'" ;;
    plain)  pr_merge 101; echo p > "$R/p"; git -C "$R" add p; git -C "$R" commit -q -m "a direct push" ;;
    none)   ;;
  esac
  RED=$(git -C "$R" rev-parse HEAD)
  echo green > "$D1/answers/$GREEN"
  echo "${M101:-$RED}" > "$D1/bisect-found"
  printf 'source=flag\nslug=%s\nred=%s\ngreen=%s\nrun=1\nwf=Harness CI\njob=2\nsuites=tests/a.sh tests/b.sh\noutcome=\n' \
    "$SLUG" "$RED" "$GREEN" > "$D1/ep-src/ep1"
}
drive() {
  env -i PATH="$PATH" HOME="$D1" HARNESS="$H" HARNESS_TEST_SANDBOX=1 HARNESS_REPO="$SLUG" \
    MAIN_RED_BISECT_FIXTURE="$D1/fakes.sh" REPOS_ROOT="$D1/repos" "$@" bash "$LANE" >"$D1/out" 2>&1
}
probes() { cnt "$D1/calls" '^probe '; }
acts() { cnt "$D1/calls" '^act_'; }
rows() { cnt "$D1/ledger" " $1\$"; }
pending() { find "$H/state/main-red-bisect/pending" -name '*.ep' 2>/dev/null | wc -l | tr -d ' '; }

# ── R1: one PR merge -> no probe, one act at once ───────────────────────────
M101=""; world one
drive
check "R1 makes no probe (got $(probes)): $(cat "$D1/calls" 2>/dev/null)" '[ "$(probes)" = 0 ]'
check "R1 never calls mrb_bisect" '[ "$(cnt "$D1/calls" "^bisect ")" = 0 ]'
check "R1 one act, and it is mrb_act_culprit" '[ "$(acts)" = 1 ] && [ "$(cnt "$D1/calls" "^act_culprit ")" = 1 ]'
check "R1 culprit is merge #101" '[ "$(epget "$D1/acted.1" culprit)" = "$M101" ]'
check "R1 pr=101" '[ "$(epget "$D1/acted.1" pr)" = 101 ]'
check "R1 pr_branch" '[ "$(epget "$D1/acted.1" pr_branch)" = ticket/bh-101 ]'
check "R1 pr_title is the merge body line" '[ "$(epget "$D1/acted.1" pr_title)" = "BH-101: title for bh-101" ]'
check "R1 steps=0 (got $(epget "$D1/acted.1" steps))" '[ "$(epget "$D1/acted.1" steps)" = 0 ]'
check "R1 shortcut=one-merge" '[ "$(epget "$D1/acted.1" shortcut)" = one-merge ]'
check "R1 no bisect= key (no empty table)" '[ "$(cnt "$D1/acted.1" "^bisect=")" = 0 ]'
check "R1 the still-red check ran before the act" '[ "$(grep -E "^(still_red|act_)" "$D1/calls" | head -1 | cut -d" " -f1)" = still_red ]'
check "R1 row culprit" '[ "$(rows culprit)" = 1 ]'
check "R1 no pending file left" '[ "$(pending)" = 0 ]'
check "R1 no warn" '[ "$(cnt "$D1/alerts" "^--severity warn ")" = 0 ]'
cp "$D1/acted.1" "$T/r1.ep" 2>/dev/null
R1_M101="$M101"; R1_GREEN="$GREEN"; R1_REPO="$T/r1-repo"
cp -r "$R" "$R1_REPO"

# ── R1c: the same span, already green again -> stale, no act ────────────────
M101=""; world one; echo 1 > "$D1/stale-rc"
drive
check "R1c no act" '[ "$(acts)" = 0 ]'
check "R1c row stale" '[ "$(rows stale)" = 1 ]'
check "R1c no probe" '[ "$(probes)" = 0 ]'

# ── R2: two PR merges -> today's P0, P1 and bisect ──────────────────────────
M101=""; world two; echo "$M102" > "$D1/bisect-found"
drive
check "R2 P0 at green" '[ "$(cnt "$D1/calls" "^probe $GREEN ")" -ge 1 ]'
check "R2 P1 at red" '[ "$(cnt "$D1/calls" "^probe $RED ")" -ge 1 ]'
check "R2 mrb_bisect gets MAX_STEPS-2 over 2 merges" '[ "$(cnt "$D1/calls" "^bisect budget=6 n=2\$")" = 1 ]'
check "R2 one act on #102" '[ "$(acts)" = 1 ] && [ "$(epget "$D1/acted.1" pr)" = 102 ]'
check "R2 no shortcut= key" '[ "$(cnt "$D1/acted.1" "^shortcut=")" = 0 ]'
check "R2 the bisect table still rides along" '[ -n "$(epget "$D1/acted.1" bisect)" ]'

# ── R2b: one merge that is not a PR merge -> today's path ───────────────────
M101=""; world branch
drive
check "R2b probes run (P0 and P1)" '[ "$(cnt "$D1/calls" "^probe $GREEN ")" -ge 1 ] && [ "$(cnt "$D1/calls" "^probe $RED ")" -ge 1 ]'
check "R2b no act, row aborted" '[ "$(acts)" = 0 ] && [ "$(rows aborted)" = 1 ]'

# ── R2c: one PR merge plus one direct commit on the first parent ────────────
M101=""; world plain
drive
check "R2c probes run (P0 and P1)" '[ "$(cnt "$D1/calls" "^probe $GREEN ")" -ge 1 ] && [ "$(cnt "$D1/calls" "^probe $RED ")" -ge 1 ]'
check "R2c bisect over 2 first-parent commits" '[ "$(cnt "$D1/calls" "^bisect budget=6 n=2\$")" = 1 ]'
check "R2c acted on #101 without shortcut=" '[ "$(epget "$D1/acted.1" pr)" = 101 ] && [ "$(cnt "$D1/acted.1" "^shortcut=")" = 0 ]'

# ── R2d: no merge at all -> today's path ────────────────────────────────────
M101=""; world none
drive
check "R2d probes run" '[ "$(probes)" -ge 1 ]'
check "R2d no act, today's flake row (green == red runs green)" '[ "$(acts)" = 0 ] && [ "$(rows flake)" = 1 ]'

# ════════════════════════════ ACT ═══════════════════════════════════════════
A="$T/act"
AH="$A/h"; SB="$A/sb"
mkdir -p "$SB" "$AH/bin" "$AH/catalog" "$AH/env" "$AH/logs" "$AH/state" "$A/tmp" "$A/ledger"
: > "$AH/env/global.env"
cp "$REPO_ROOT/catalog/test-impact-always.txt" "$AH/catalog/"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/calls.alert"\n' "$A" > "$AH/bin/lane-alert.sh"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/calls.verdict"\n' "$A" > "$AH/bin/lead-verdict.sh"
cat > "$SB/gh" <<SH
#!/bin/bash
m=GET p="" n=\$(ls "$A" | grep -c '^payload\.')
shift # api
while [ \$# -gt 0 ]; do
  case "\$1" in
    -i) ;;
    -X) m="\$2"; shift ;;
    --input) n=\$((n+1)); cp "\$2" "$A/payload.\$n"; echo "\$n" > "$A/pay.last"; shift ;;
    -F|-f|-H) shift ;;
    *) [ -z "\$p" ] && p="\$1" ;;
  esac; shift
done
printf '%s %s\n' "\$m" "\$p" >> "$A/calls.gh"
[ -f "$A/pay.last" ] && { printf '%s %s %s\n' "\$(cat "$A/pay.last")" "\$m" "\$p" >> "$A/calls.pay"; rm -f "$A/pay.last"; }
case "\$m \$p" in
  "POST repos/$SLUG/pulls") printf 'HTTP/2 201\n\n{"number":500,"html_url":"https://github.com/$SLUG/pull/500"}\n' ;;
  "GET repos/$SLUG/pulls?"*) printf 'HTTP/2 200\n\n[]\n' ;;
  "POST repos/$SLUG/issues/"*/labels) printf 'HTTP/2 200\n\n[{"name":"x"}]\n' ;;
  "GET repos/$SLUG/issues") printf 'HTTP/2 200\n\n[]\n' ;;
  "POST repos/$SLUG/issues") printf 'HTTP/2 201\n\n{"number":601,"html_url":"https://github.com/$SLUG/issues/601"}\n' ;;
  *) printf 'HTTP/2 500\n\n{}\n' ;;
esac
SH
cat > "$SB/curl" <<SH
#!/bin/bash
m=GET d="" url=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    -X) m="\$2"; shift ;;
    --data-binary) d="\$2"; shift ;;
    -m|--connect-timeout|-w|-H) shift ;;
    -*) ;;
    *) url="\$1" ;;
  esac; shift
done
p="\${url#http://stub}"
answer() { printf '%s\n%s' "\$1" "\$2"; exit 0; }
case "\$m \$p" in
  "GET /api/ledger?"*)
    f="$A/ledger/\$(printf '%s' "\${p#*\\?}" | sha1sum | cut -c1-16)"
    [ -f "\$f" ] && answer "{\"ledger\":\$(cat "\$f")}" 200
    answer '{"error":"not found"}' 404 ;;
  "PUT /api/ledger")
    q=\$(printf '%s' "\$d" | jq -r '"kind="+(.kind|@uri)+"&key="+(.key|@uri)')
    printf '%s' "\$d" | jq -c '{status, detail: (.detail // "")}' > "$A/ledger/\$(printf '%s' "\$q" | sha1sum | cut -c1-16)"
    printf '%s' "\$d" | jq -r '"\(.kind) \(.key) \(.status) \(.detail // "")"' >> "$A/calls.ledger"
    answer '{"ok":true}' 200 ;;
  *) answer '{}' 404 ;;
esac
SH
chmod +x "$SB/gh" "$SB/curl" "$AH/bin/"*.sh

# act_run <episode> — the real mrb_act_culprit in a subshell over a fresh remote
# and ledger built from R1's repo. Leaves the recorders in $A.
act_run() {
  scratch_rm "$A/remote.git"; scratch_rm "$A/clone"; scratch_rm "$A/ledger"; mkdir -p "$A/ledger"
  rm -f "$A"/calls.* "$A"/payload.* "$A/pay.last"
  git init -q --bare -b main "$A/remote.git"
  git -C "$R1_REPO" push -q "$A/remote.git" main
  git clone -q "$A/remote.git" "$A/clone"
  (
    export PATH="$SB:$PATH" HARNESS="$AH" JOBS_URL=http://stub HARNESS_SECRET=x-fixture JOBS_RETRIES=0 \
      TMPDIR="$A/tmp" HOME="$A" GH_ETAG=0 MRB_REPO_DIR="$A/clone"
    . "$REPO_ROOT/bin/jobs-client.sh" || exit 90
    . "$REPO_ROOT/bin/lib/mrb-act.sh" || exit 91
    gh_default_auth_for_slug() { :; }
    mrb_act_culprit "$1"
  ) > "$A/out" 2> "$A/err"
  ARC=$?
}
payload() { # payload <METHOD path regex> -> the last matching payload file
  local n; n=$(grep -E "^[0-9]+ $1\$" "$A/calls.pay" 2>/dev/null | tail -1 | cut -d' ' -f1)
  [ -n "$n" ] && printf '%s' "$A/payload.$n"
}

# ── R1b / R3 / R3b / R5: R1's episode through the real act ──────────────────
act_run "$T/r1.ep"
check "R1b act rc 0 (got $ARC): $(tail -3 "$A/err" 2>/dev/null)" '[ "$ARC" = 0 ]'
check "R1b one pulls POST" '[ "$(cnt "$A/calls.gh" "^POST repos/$SLUG/pulls\$")" = 1 ]'
check "R1b labels fix-main-red + hotfix" \
  '[ "$(jq -c .labels "$(payload "POST repos/$SLUG/issues/500/labels")" 2>/dev/null)" = "[\"fix-main-red\",\"hotfix\"]" ]'
check "R1b one re-land issue POST" '[ "$(cnt "$A/calls.gh" "^POST repos/$SLUG/issues\$")" = 1 ]'
PB=$(jq -r .body "$(payload "POST repos/$SLUG/pulls")" 2>/dev/null)
IB=$(jq -r .body "$(payload "POST repos/$SLUG/issues")" 2>/dev/null)
check "R3 the PR body names the red suites" '[[ "$PB" == *"Red suites: tests/a.sh tests/b.sh"* ]]'
check "R3b the PR body has the one-merge line" \
  '[[ "$PB" == *"Merge $R1_M101 (#101) is the only merge since the last green $R1_GREEN, so this reverts it without a bisect."* ]]'
check "R3b the PR body does not say the bisect pinned it" '[[ "$PB" != *"The bisect pinned"* ]]'
check "R3b the PR body has no Bisect: fence" '[[ "$PB" != *"Bisect:"* ]]'
check "R3b the re-land body has the one-merge line" '[[ "$IB" == *"is the only merge since the last green"* ]] && [[ "$IB" != *"The bisect pinned"* ]]'
AL=$(grep -- '--severity warn --id main-red-revert:' "$A/calls.alert" 2>/dev/null)
check "R5 one revert warn alert" '[ "$(printf "%s\n" "$AL" | grep -c .)" = 1 ]'
check "R5 the alert names #101" '[[ "$AL" == *"#101"* ]]'
check "R5 the alert names the suites" '[[ "$AL" == *"tests/a.sh tests/b.sh"* ]]'
check "R5 the alert names the revert PR" '[[ "$AL" == *"https://github.com/$SLUG/pull/500"* ]]'
check "R5 the alert names the re-land ticket" '[[ "$AL" == *"https://github.com/$SLUG/issues/601"* ]]'
check "R5 the alert says no bisect" '[[ "$AL" == *"no bisect"* ]]'

# The same episode without the shortcut key: today's wording, byte for byte.
grep -v '^shortcut=' "$T/r1.ep" > "$T/r1-bisect.ep"
act_run "$T/r1-bisect.ep"
PB=$(jq -r .body "$(payload "POST repos/$SLUG/pulls")" 2>/dev/null)
IB=$(jq -r .body "$(payload "POST repos/$SLUG/issues")" 2>/dev/null)
AL=$(grep -- '--severity warn --id main-red-revert:' "$A/calls.alert" 2>/dev/null)
check "R3b a bisected episode keeps today's first line" \
  '[ "$(printf "%s\n" "$PB" | sed -n 3p)" = "Main went red in https://github.com/$SLUG/actions/runs/1. The bisect pinned it on merge $R1_M101 (#101), so this reverts it." ]'
check "R3b a bisected re-land keeps today's line" '[[ "$IB" == *"Merge #101 (BH-101: title for bh-101) broke main. The bisect pinned the red on it."* ]]'
check "R3b a bisected alert has no one-merge suffix" '[[ -n "$AL" ]] && [[ "$AL" != *"no bisect"* ]]'

# ════════════════════════════ RECHECK ═══════════════════════════════════════
C="$T/rck"
mkdir -p "$C/bin/lib" "$C/logs" "$C/state" "$C/flags" "$C/locks" "$C/env" "$C/fakebin" "$C/pages" "$C/ledger" "$C/catalog"
: > "$C/env/global.env"
printf '#!/bin/bash\nexit 0\n' > "$C/bin/beat.sh"; chmod +x "$C/bin/beat.sh"
cat > "$C/bin/lane-alert.sh" <<'SHIM'
#!/bin/bash
printf '%s\n' "$*" >> "$ALERT_SINK"
exit 0
SHIM
chmod +x "$C/bin/lane-alert.sh"
cat > "$C/bin/jobs-client.sh" <<'SHIM'
flag_set() { printf '%s %s %s\n' "$1" "$2" "${3:-}" >> "$PUBLISH_SINK"; return 0; }
_lrow() { printf '%s/%s__%s' "$LEDGER_DIR" "$1" "$(printf '%s' "$2" | tr '/' '-')"; }
job_ledger_get() {
  local f; f=$(_lrow "$1" "$2"); [ -f "$f" ] || return 2
  cat "$f"; return 0
}
job_ledger_put() { printf '%s' "$3" > "$(_lrow "$1" "$2")"; return 0; }
_jobs_req() { case "$2" in /api/settings) printf '{"settings":[]}' ;; *) return 1 ;; esac; }
SHIM
cat > "$C/fakebin/gh" <<'SHIM'
#!/bin/bash
printf '%s\n' "$*" >> "$GH_SINK"
case "$*" in
  "api repos/"*" -q .id") exit 0 ;;
  *"/actions/runs/"*) echo "" ;;
  *"actions/runs"*)
    slug=""; q=""; prev=""
    for a in "$@"; do
      case "$a" in repos/*/actions/runs) slug=${a#repos/}; slug=${slug%/actions/runs} ;; esac
      [ "$prev" = -q ] && q="$a"; prev="$a"
    done
    f="$RCK/pages/$(printf '%s' "$slug" | tr '/' '-').json"
    [ -s "$f" ] || exit 0
    if [ -n "$q" ]; then jq -c "$q" "$f"; else cat "$f"; fi ;;
  *) echo "" ;;
esac
SHIM
chmod +x "$C/fakebin/gh"
( cd "$REPO_ROOT" && scratch_install_closure bin/main-red-recheck.sh "$C" ) >/dev/null || bad "setup: recheck closure install failed"
( cd "$REPO_ROOT" && scratch_install_closure bin/main-red-detector.sh "$C" ) >/dev/null || bad "setup: detector closure install failed"
cp "$(rendered_registry)" "$C/catalog/lanes.json" || bad "setup: no rendered registry"

CI=".github/workflows/ci.yml"
RSHA=94413268a1b2c3d4e5f60718293a4b5c6d7e8f90
r_page() { # r_page <conclusion of the newest run, on RSHA>
  local out='[' first=1 spec id c t u sha a
  for spec in "38322322575|$1|2026-10-13T15:26:00Z|2026-10-13T16:20:00Z|$RSHA|2" \
              "38322235694|success|2026-10-13T15:00:00Z|2026-10-13T15:10:00Z|green0003|1" \
              "38318317991|success|2026-10-13T14:00:00Z|2026-10-13T14:10:00Z|green0002|1"; do
    IFS='|' read -r id c t u sha a <<<"$spec"
    [ "$first" = 1 ] || out+=','; first=0
    out+=$(jq -nc --arg id "$id" --arg c "$c" --arg t "$t" --arg u "$u" --arg sha "$sha" --arg a "$a" --arg p "$CI" '
      {id:($id|tonumber), name:"ci", path:$p, status:"completed", conclusion:$c, head_sha:$sha,
       event:"push", created_at:$t, updated_at:$u, run_attempt:($a|tonumber),
       html_url:("https://github.com/o/r/actions/runs/" + $id)}')
  done
  jq -nc --argjson r "$out]" '{total_count:64, workflow_runs:$r}' > "$C/pages/o-r.json"
}
iso_ago() { date -u -d "@$(( $(date +%s) - $1 ))" '+%Y-%m-%dT%H:%M:%SZ'; }
flag() { # flag [extra key=value lines] — the o/r freeze body
  printf 'sha=%s\nworkflow=ci\npath=%s\nreason=tip\nrun=https://github.com/o/r/actions/runs/38322322575\n%s' \
    "$RSHA" "$CI" "${1:-}" > "$C/flags/main-red-o-r"
}
rcase() {
  : > "$C/alerts.txt"; : > "$C/publish.txt"; : > "$C/logs/main-red.log"; : > "$C/gh.txt"
  rm -f "$C"/flags/* "$C"/locks/* "$C"/ledger/* "$C"/pages/*.json
  scratch_rm "$C/state/main-red"; scratch_rm "$C/state/lane-gate"
  printf 'total=64 newest=2026-10-13T15:26:00Z' > "$C/ledger/main_red_runs__o-r"
}
recheck() {
  ( export PATH="$C/fakebin:$PATH" HARNESS="$C" RCK="$C" GH_SINK="$C/gh.txt" ALERT_SINK="$C/alerts.txt" \
      PUBLISH_SINK="$C/publish.txt" LEDGER_DIR="$C/ledger" MAIN_RED_QUEUE=0 HARNESS_REPO=o/harness \
      MAIN_RED_REPOS="o/r" FLEET_CONF="$C/fleet.conf"
    unset REGISTRY_SOURCE GH_TOKEN LANE_START_SPREAD_S MAIN_RED_RECHECK_MIN
    bash "$C/bin/main-red-recheck.sh" >"$C/out.txt" 2>"$C/err.txt" ); RRC=$?
}
lifted() { cnt "$C/logs/main-red.log" 'main-red-recheck: FREEZE_LIFTED '; }
after() { sed -n 's/.*FREEZE_LIFTED after=\([0-9]*\) .*/\1/p' "$C/logs/main-red.log" | head -1; }
in_range() { [ -n "$1" ] && [ "$1" -ge "$2" ] && [ "$1" -le "$3" ]; }

# ── R4: green again -> the flag lifts, one FREEZE_LIFTED line ───────────────
rcase; flag "since=$(iso_ago 5400)"$'\n'; r_page success
recheck
check "R4 the flag is gone (rc $RRC): $(tail -5 "$C/logs/main-red.log")" '[ ! -e "$C/flags/main-red-o-r" ]'
check "R4 one FREEZE_LIFTED line: $(tail -3 "$C/logs/main-red.log")" '[ "$(lifted)" = 1 ]'
check "R4 the line names the flag" '[ "$(cnt "$C/logs/main-red.log" "FREEZE_LIFTED after=[0-9]+ flag=main-red-o-r\$")" = 1 ]'
check "R4 after= is 90 min (got $(after))" 'in_range "$(after)" 89 91'
check "R4 the recheck rc is the detector rc 0" '[ "$RRC" = 0 ]'

# ── R4b: still red on the same sha -> the flag stays, no line ───────────────
rcase; flag "since=$(iso_ago 5400)"$'\n'; r_page failure
recheck
check "R4b the flag stays" '[ -e "$C/flags/main-red-o-r" ]'
check "R4b no FREEZE_LIFTED line" '[ "$(lifted)" = 0 ]'

# ── R4c: no freeze up -> no detector, no line, rc 0 ─────────────────────────
rcase; r_page success
recheck
check "R4c rc 0 (got $RRC)" '[ "$RRC" = 0 ]'
check "R4c no detector start, no GitHub read" '[ ! -s "$C/gh.txt" ] && [ "$(cnt "$C/logs/main-red.log" "pass start:")" = 0 ]'
check "R4c no FREEZE_LIFTED line" '[ "$(lifted)" = 0 ]'

# ── R4d: raised= wins over since= ───────────────────────────────────────────
rcase; flag "since=$(iso_ago 5400)"$'\n'"raised=$(iso_ago 1800)"$'\n'; r_page success
recheck
check "R4d after= counts from raised= (got $(after))" '[ "$(lifted)" = 1 ] && in_range "$(after)" 29 31'

# ── R4e: no raised= and no since= -> the file mtime ─────────────────────────
rcase; flag; touch -d "@$(( $(date +%s) - 2700 ))" "$C/flags/main-red-o-r"; r_page success
recheck
check "R4e after= counts from the mtime (got $(after))" '[ "$(lifted)" = 1 ] && in_range "$(after)" 44 46'

# ── R4f: a start in the future -> after=0, never negative ───────────────────
rcase; flag "since=$(date -u -d "@$(( $(date +%s) + 3600 ))" '+%Y-%m-%dT%H:%M:%SZ')"$'\n'; r_page success
recheck
check "R4f after=0 (got $(after))" '[ "$(lifted)" = 1 ] && [ "$(after)" = 0 ]'

echo "main-red-direct-revert.bh-6747-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
