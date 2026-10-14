#!/bin/bash
# tests/ticket-branch-ratchet.bh-3835-test.sh — BH-3835: the shared ticket-branch
# parser (bin/lib/ticket-branch.sh) and a ratchet over bin/.
#
#   U*  ticket_branch_key / ticket_branch_issue accept ticket/<prefix>-<n> and
#       its rebuild-ladder form ticket/<prefix>-<n>-r<k>, and nothing else.
#   R*  every non-comment line under bin/ holding an anchored ^ticket/ regex also
#       allows the -r<k> suffix, i.e. carries a "(-r[0-9]" or "(-r\d" group. A
#       site that does not is how BH-3835 happened: dequeue-watch could not find
#       the issue of a culprit on ticket/bh-77-r2.
# Run from anywhere: tests/ticket-branch-ratchet.bh-3835-test.sh   (exit 0 = all pass)
. "$(dirname "$0")/lib/scratch.sh" || exit 1
set -uo pipefail
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
LIB="$DIR/bin/lib/ticket-branch.sh"

# ── U*: the lib ───────────────────────────────────────────────────────────────
if [ -f "$LIB" ] && . "$LIB"; then
  for ref in ticket/bh-77 ticket/bh-77-r2 ticket/BH-77-r2 ticket/bh-77-r12; do
    out=$(ticket_branch_key "$ref"); rc=$?
    [ "$rc" = 0 ] && [ "$out" = BH-77 ] && ok || bad "U1: ticket_branch_key $ref -> '$out' rc $rc, want BH-77 rc 0"
  done
  out=$(ticket_branch_key ticket/ab2-9); [ "$out" = AB2-9 ] && ok || bad "U1: ticket/ab2-9 -> '$out', want AB2-9"
  out=$(ticket_branch_issue ticket/bh-77-r2); rc=$?
  [ "$rc" = 0 ] && [ "$out" = 77 ] && ok || bad "U2: ticket_branch_issue ticket/bh-77-r2 -> '$out' rc $rc, want 77 rc 0"
  out=$(ticket_branch_issue ticket/bh-3729); [ "$out" = 3729 ] && ok || bad "U2: ticket/bh-3729 -> '$out', want 3729"
  nl=$'ticket/bh-77\n'
  for ref in ticket/bh-77-R2 ticket/bh-77-r ticket/bh-77-r2-x ticket/bh-1510-0 ticket/bh-1486-local \
             ticket/bh-77-rr2 feature/bh-77 mergify/merge-queue/main/x ticket/77 "" "$nl" ticket/bh-77.0 \
             xticket/bh-77 ticket/-77; do
    out=$(ticket_branch_key "$ref"); rc=$?
    [ "$rc" = 1 ] && [ -z "$out" ] && ok || bad "U3: ticket_branch_key '$ref' -> '$out' rc $rc, want '' rc 1"
    out=$(ticket_branch_issue "$ref"); rc=$?
    [ "$rc" = 1 ] && [ -z "$out" ] && ok || bad "U3: ticket_branch_issue '$ref' -> '$out' rc $rc, want '' rc 1"
  done
  out=$(set -u; ticket_branch_key 2>&1); rc=$?
  [ "$rc" = 1 ] && [ -z "$out" ] && ok || bad "U3: no argument under set -u -> '$out' rc $rc"
else
  bad "U1: $LIB is missing or could not be sourced"
fi

# U4: bash-3.2 shape
if [ -f "$LIB" ]; then
  bash -n "$LIB" && ok || bad "U4: bash -n $LIB"
  if grep -nE '\$\{[A-Za-z_]+(\^\^|,,)\}|declare -A|mapfile|readarray|=~ *"' "$LIB"; then
    bad "U4: $LIB uses a bash-4-only construct or a quoted regex (lines above)"
  else ok; fi
  # nothing runs on source: a sourced copy defines functions and leaves no variable behind
  out=$(env -i PATH="$PATH" bash -c 'before=$(compgen -v | sort); . "$1"; after=$(compgen -v | sort); comm -13 <(echo "$before") <(echo "$after") | grep -vE "^(before|_|PIPESTATUS|BASH_[A-Z_]*)$"' _ "$LIB")
  [ -z "$out" ] && ok || bad "U4: sourcing the lib left variables: $out"
  if /bin/bash --version 2>/dev/null | head -1 | grep -q 'version 3\.'; then
    out=$(/bin/bash -c '. "$1"; ticket_branch_key ticket/bh-77-r2' _ "$LIB")
    [ "$out" = BH-77 ] && ok || bad "U4: under bash 3 ticket_branch_key -> '$out'"
  else
    echo "note: U4 is shape-only here, /bin/bash is not 3.x"
  fi
fi

# ── R*: the ratchet ───────────────────────────────────────────────────────────
# scan <root> — prints every candidate line (file:line:text) under <root>/bin
# holding an anchored ^ticket/ regex, comment lines dropped.
scan() {
  ( cd "$1" && grep -rnI --exclude='*.pyc' --exclude-dir=__pycache__ -E '\^ticket/' bin/ ) \
    | awk '{ s = $0; sub(/^[^:]*:[0-9]+:/, "", s); if (s !~ /^[ \t]*#/) print }'
}
# offenders <root> — the candidates that do not allow the -r<k> suffix.
offenders() { scan "$1" | grep -vE '\(-r(\[0-9\]|\\d)' || true; }

cand=$(scan "$DIR"); off=$(offenders "$DIR")
if [ -z "$off" ]; then ok; else
  while IFS= read -r l; do bad "R1: ${l%%:*}:$(printf '%s' "$l" | cut -d: -f2) matches a ticket branch without allowing -r<k>: $l"; done <<< "$off"
fi
nc=$(printf '%s\n' "$cand" | grep -c . || true)
[ "$nc" -ge 5 ] && ok || bad "R2: the scan found only $nc candidate lines under bin/, want >= 5 (a broken scan must not pass)"
for f in bin/lib/pr-dep-gate.sh bin/dep-verify.sh bin/unblocked-children.sh bin/decompose-parent-close.sh bin/lib/ticket-branch.sh; do
  grep -q "^$f:" <<<"$cand" && ok || bad "R2: the scan did not see $f"
done

# R3: mutation seed — a scratch tree with suffix-less sites is flagged
mkdir -p "$T/seed/bin/lib"
cat > "$T/seed/bin/lib/bad.sh" <<'EOF'
f() { [[ "$r" =~ ^ticket/[A-Za-z]+-([0-9]+)$ ]] && echo "${BASH_REMATCH[1]}"; }
EOF
cat > "$T/seed/bin/bad.py" <<'EOF'
br = re.compile(r"^ticket/[a-z0-9]+-%d$" % n)
EOF
cat > "$T/seed/bin/good.sh" <<'EOF'
# [[ "$r" =~ ^ticket/[A-Za-z]+-([0-9]+)$ ]]
  # br = re.compile(r"^ticket/[a-z0-9]+-%d$" % n)
g() { local re='^ticket/([A-Za-z]+)-([0-9]+)(-r[0-9]+)?$'; [[ $1 =~ $re ]]; }
br = re.compile(r"^ticket/[a-z0-9]+-%d(-r\d+)?$" % n)
EOF
off=$(offenders "$T/seed")
grep -q '^bin/lib/bad.sh:1:' <<<"$off" && ok || bad "R3: the seed bash site was not flagged: $off"
grep -q '^bin/bad.py:1:' <<<"$off" && ok || bad "R3: the seed python site was not flagged: $off"
grep -q '^bin/good.sh:' <<<"$off" && bad "R3: a commented or suffix-aware line was flagged: $off" || ok

echo "ticket-branch-ratchet.bh-3835: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
