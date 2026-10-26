#!/bin/bash
# tests/no-harness-export-test.sh — a bin/ lane must not EXPORT HARNESS.
#
# WHY THIS EXISTS. The 2026-09-15 hub wipe (#388, root cause #404) was a test
# that re-derived a harness root it did not own and deleted it. `export
# HARNESS="$H"` at the top of a lane is the same hole one layer up: every child
# of that lane — stubs, sourced libs, an agent session, a test the agent then
# runs — inherits a live harness root nobody handed it on purpose. #394.5 (#463)
# takes the export out of the two lanes that spawn the most children and passes
# the value explicitly to the children that actually need it.
#
# WHAT IT PINS, for bin/blocked-resolver.sh and bin/fleet-propagate.sh:
#   * no `export HARNESS=` anywhere in the file;
#   * exactly one `H="${HARNESS:-/root/harness}"` — the value still resolves the
#     same way, it is just not pushed into the environment;
#   * no bare `$HARNESS` left behind: with the export gone and `set -u` on, one
#     unguarded reference kills the lane on a cron run with a stripped env;
#   * the named children still receive it (`HARNESS="$H" timeout …`);
#   * `bash -n`.
#
# Every one of those rules is ALSO run against a deliberately broken copy of the
# same file (section B). A rule that cannot go red is a comment, and this suite
# is the kind that would quietly become one.
#
# Section C and D RUN the real scripts with HARNESS absent from the environment
# and read what the children saw, because "it does not export" is a fact about
# the child's environment, not about the text.
#
# A LANE IS NOT THE ONLY THING THAT RESOLVES A ROOT. bin/lib/merge-conductor-lib.sh
# (`MC_H`) and bin/jobs-client.sh (`JOBS_HARNESS`) each read `${HARNESS:-/root/harness}`
# themselves rather than taking the lane's $H. That needs no product change: they
# only diverge from the lane when HARNESS is in the environment, and then the child
# has inherited it already. It does change what a TEST has to do — with HARNESS
# unset, a copied lib falls back to the real /root/harness, so section D rewrites
# the copied lib's default for the same reason it rewrites the lane's, and asserts
# the resulting state tree landed under the scratch root.
#
# Self-contained: no network, no secrets, no live $HARNESS. Everything is under
# the scratch tree.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

FILES="bin/blocked-resolver.sh bin/fleet-propagate.sh"

# ── the rules, as functions: 0 = the file is clean, 1 = the file violates ────
rule_no_export() { # no `export HARNESS=` at all
  ! grep -qE '^[[:space:]]*export[[:space:]]+HARNESS=' "$1"
}
rule_one_default() { # exactly one H="${HARNESS:-/root/harness}"
  [ "$(grep -cE '^H="\$\{HARNESS:-/root/harness\}"$' "$1")" = 1 ]
}
rule_no_bare() { # no $HARNESS / ${HARNESS} reference without a :- default
  # grep -c, not grep -qv: it reads to EOF, so a match cannot SIGPIPE the
  # producer into reading as "no bare reference" (BH-1818).
  [ "$(grep -E '\$\{?HARNESS([^_A-Za-z]|$)' "$1" | grep -vc 'HARNESS:-')" = 0 ]
}
rule_child_pass() { # every child call the ticket names carries HARNESS="$H"
  [ "$(grep -cE 'HARNESS="\$H" (timeout|setsid)' "$1")" = "$2" ]
}

# ── A. the real files obey every rule ───────────────────────────────────────
for F in $FILES; do
  P="$DIR/$F"
  [ -s "$P" ] || { bad "$F is missing or empty — the rules below would pass vacuously"; continue; }
  rule_no_export   "$P" && ok || bad "$F still exports HARNESS: $(grep -nE '^[[:space:]]*export[[:space:]]+HARNESS=' "$P")"
  rule_one_default "$P" && ok || bad "$F must keep exactly one H=\"\${HARNESS:-/root/harness}\" (found $(grep -cE '^H="\$\{HARNESS:-/root/harness\}"$' "$P"))"
  rule_no_bare     "$P" && ok || bad "$F references \$HARNESS with no default, which is an unbound variable under set -u once the export is gone: $(grep -nE '\$\{?HARNESS([^_A-Za-z]|$)' "$P" | grep -v 'HARNESS:-')"
  bash -n "$P" 2>"$T/syntax.err" && ok || bad "$F does not parse: $(cat "$T/syntax.err")"
done
# The two timeout children plus the setsid resume in blocked-resolver.sh; the
# harness-sync, fly-image-build and prompt-render (BH-7971: it renders into
# $H/state/prompts, so a scratch root must reach it) children in fleet-propagate.sh.
rule_child_pass "$DIR/bin/blocked-resolver.sh" 3 && ok \
  || bad "bin/blocked-resolver.sh must hand HARNESS=\"\$H\" to its 3 named children (found $(grep -cE 'HARNESS="\$H" (timeout|setsid)' "$DIR/bin/blocked-resolver.sh"))"
rule_child_pass "$DIR/bin/fleet-propagate.sh" 3 && ok \
  || bad "bin/fleet-propagate.sh must hand HARNESS=\"\$H\" to its 3 named children (found $(grep -cE 'HARNESS="\$H" (timeout|setsid)' "$DIR/bin/fleet-propagate.sh"))"

# ── B. every rule FIRES on a broken copy of the same file ───────────────────
# Red-first, permanently: each rule is re-run against a copy carrying exactly
# the defect it exists to catch. A rule that stays green here is not a rule.
mkdir -p "$T/broken"
BR="$DIR/bin/blocked-resolver.sh"

cp "$BR" "$T/broken/exported.sh"
printf 'export HARNESS="$H"\n' >> "$T/broken/exported.sh"
rule_no_export "$T/broken/exported.sh" && bad "rule_no_export passed a file that exports HARNESS" || ok

grep -v '^H="\${HARNESS:-/root/harness}"$' "$BR" > "$T/broken/nodefault.sh"
rule_one_default "$T/broken/nodefault.sh" && bad "rule_one_default passed a file with no H= default" || ok

cp "$BR" "$T/broken/bare.sh"
printf 'mkdir -p "$HARNESS/tmp/brfix"\n' >> "$T/broken/bare.sh"
rule_no_bare "$T/broken/bare.sh" && bad "rule_no_bare passed a file with a bare \$HARNESS" || ok

sed 's|HARNESS="\$H" timeout|timeout|' "$BR" > "$T/broken/nopass.sh"
rule_child_pass "$T/broken/nopass.sh" 3 && bad "rule_child_pass passed a file whose children lost HARNESS=\"\$H\"" || ok

# ── C. fleet-propagate.sh, run for real with HARNESS absent ─────────────────
# The whole script, from its own entry point, with HARNESS nowhere in the
# environment: the named children must still be handed the root, and the
# children the ticket does NOT name must not see one.
FH="$T/fp"                       # the scratch harness this run resolves to
mkdir -p "$FH/bin" "$FH/flags" "$T/fpbin"
# Only the default-root line is rewritten, so the run is the shipped script
# resolving a scratch root the way a box resolves /root/harness.
sed 's|^H="${HARNESS:-/root/harness}"$|H="${HARNESS:-'"$FH"'}"|' \
  "$DIR/bin/fleet-propagate.sh" > "$FH/bin/fleet-propagate.sh"
scratch_install_closure bin/lib/fleet-paths.sh "$FH" >/dev/null || exit 1   # BH-5247: FLEET_PATHS, or the run fails closed
grep -q "HARNESS:-$FH" "$FH/bin/fleet-propagate.sh" && ok \
  || bad "the default-root rewrite did not match bin/fleet-propagate.sh — section C would be testing nothing"

printf 'tproj o/tproj - - 2 box-tproj 100.0.0.9\n' > "$FH/fleet.conf"
: > "$FH/flags/fly-pool-app-tproj"

# Every stub records whether HARNESS reached it. "<unset>" is the answer that
# matters: it is what the export used to make impossible.
mkstub() { # mkstub <path> <extra body>
  { printf '#!/bin/bash\n'
    printf 'printf "%%s %%s\\n" "%s" "${HARNESS-<unset>}" >> "$CHILD_ENV"\n' "${1##*/}"
    printf '%s\n' "${2:-exit 0}"
  } > "$1"
  chmod +x "$1"
}
mkstub "$FH/bin/harness-sync.sh"    'exit 0'
mkstub "$FH/bin/fly-image-build.sh" 'exit 0'
mkstub "$FH/bin/fleet-conf.sh"      'case "${1:-}" in --projects) echo tproj ;; --tailnet-ip-of-box) echo 100.0.0.9 ;; *) echo - ;; esac; exit 0'
mkstub "$FH/bin/box-for.sh"         'echo box-tproj; exit 0'
mkstub "$FH/bin/lane-alert.sh"      'exit 0'
cat > "$T/fpbin/ssh" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$SSH_CALLS"
echo "cafe123456789"; exit 0
EOF
# A real fly-image-build.sh running on the box that runs this suite would make
# the defer guard fire and the run skip, which would prove nothing.
printf '#!/bin/bash\nexit 1\n' > "$T/fpbin/pgrep"
chmod +x "$T/fpbin/ssh" "$T/fpbin/pgrep"

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@x GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@x
git init -q --bare "$T/origin"
git init -q -b main "$T/src" 2>/dev/null || { git init -q "$T/src"; git -C "$T/src" checkout -q -b main; }
git -C "$T/src" remote add origin "$T/origin"
mkdir -p "$T/src/bin"
echo "echo v1" > "$T/src/bin/run-build.sh"
git -C "$T/src" add -A && git -C "$T/src" commit -qm init >/dev/null && git -C "$T/src" push -q origin main
git -C "$T/origin" symbolic-ref HEAD refs/heads/main
git clone -q "$T/origin" "$T/checkout"
echo "echo v2" > "$T/src/bin/run-build.sh"
git -C "$T/src" add -A && git -C "$T/src" commit -qm "a bin/ change the fleet must see" >/dev/null
git -C "$T/src" push -q origin main

: > "$T/child-env.txt"; : > "$T/ssh.calls"
( env -u HARNESS \
    HARNESS_CHECKOUT="$T/checkout" \
    FLEET_PROPAGATE_PATH="$T/fpbin:/usr/bin:/bin:/usr/local/bin" \
    CHILD_ENV="$T/child-env.txt" SSH_CALLS="$T/ssh.calls" \
    bash "$FH/bin/fleet-propagate.sh" ) > "$T/fp.out" 2>"$T/fp.err"
FP_RC=$?

[ "$FP_RC" = 0 ] && ok || bad "fleet-propagate.sh with no HARNESS in the environment exited $FP_RC: $(tail -5 "$T/fp.err")"
grep -q 'unbound variable' "$T/fp.err" && bad "fleet-propagate.sh died on an unbound HARNESS: $(grep 'unbound variable' "$T/fp.err")" || ok
# Did the run HAPPEN? A stub list that is empty because nothing propagated is
# indistinguishable from a clean pass.
[ -s "$T/child-env.txt" ] && ok || bad "no child ran at all — section C tested nothing (out: $(cat "$T/fp.out"), err: $(tail -5 "$T/fp.err"))"
grep -q '^harness-sync.sh ' "$T/child-env.txt" && ok || bad "the hub sync child never ran: $(cat "$T/child-env.txt")"
[ "$(grep '^harness-sync.sh ' "$T/child-env.txt" | head -1 | awk '{print $2}')" = "$FH" ] && ok \
  || bad "harness-sync.sh must be handed HARNESS=\"\$H\" explicitly (saw $(grep '^harness-sync.sh ' "$T/child-env.txt" | head -1))"
[ "$(grep '^fly-image-build.sh ' "$T/child-env.txt" | head -1 | awk '{print $2}')" = "$FH" ] && ok \
  || bad "fly-image-build.sh must be handed HARNESS=\"\$H\" explicitly (saw $(grep '^fly-image-build.sh ' "$T/child-env.txt" | head -1))"
# The other half of the ticket: a child nobody named must NOT inherit a harness
# root. This is the assertion the export used to make impossible.
[ -z "$(grep -E '^(fleet-conf|box-for|lane-alert)\.sh ' "$T/child-env.txt" | awk '$2 != "<unset>"')" ] && ok \
  || bad "an unnamed child inherited HARNESS — the export is still being made somewhere: $(grep -E '^(fleet-conf|box-for|lane-alert)\.sh ' "$T/child-env.txt" | awk '$2 != "<unset>"')"
grep -qE '^(fleet-conf|box-for)\.sh ' "$T/child-env.txt" && ok \
  || bad "no unnamed child ran, so the assertion above proved nothing: $(cat "$T/child-env.txt")"

# ── D. blocked-resolver.sh starts with HARNESS absent ───────────────────────
# It is `set -u`, and it used to reference $HARNESS bare. With nothing in the
# environment that is an immediate death on a cron run with a stripped env, so
# the thing to prove is that the lane gets past its own startup and resolves the
# same root it always did.
BH="$T/br"
mkdir -p "$BH/bin/lib"
# The libs the lane reads PR state through; without them it refuses before it
# has done anything, which would make the assertions below meaningless.
cp "$DIR/bin/lib/merge-conductor-lib.sh" "$DIR/bin/lib/gh-pr-list.sh" \
   "$DIR/bin/lib/rebuild-ledger.sh" "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$BH/bin/lib/"
mkdir -p "$BH/bin/lib/mc" && cp "$DIR"/bin/lib/mc/*.sh "$BH/bin/lib/mc/"
# BH-1176: the lane sources bin/lib/br/ out of the root it resolved, and REFUSES
# the tick when a module is missing — so the modules go under the SAME rewritten
# default root the copy above resolves, not under the real /root/harness.
# shellcheck source=tests/lib/br-modules.sh
. "$DIR/tests/lib/br-modules.sh" || exit 1
br_modules_install "$DIR" "$BH" || exit 1
sed 's|^H="${HARNESS:-/root/harness}"$|H="${HARNESS:-'"$BH"'}"|' \
  "$DIR/bin/blocked-resolver.sh" > "$BH/bin/blocked-resolver.sh"
grep -q "HARNESS:-$BH" "$BH/bin/blocked-resolver.sh" && ok \
  || bad "the default-root rewrite did not match bin/blocked-resolver.sh — section D would be testing nothing"
# The lane is not the only thing that resolves a root. The conductor lib reads
# `MC_H="${HARNESS:-/root/harness}"` for itself and bin/jobs-client.sh reads
# `JOBS_HARNESS="${HARNESS:-/root/harness}"`; neither takes the lane's $H. With
# HARNESS unset — the case this section exists to drive — the copied lib fell back
# to the REAL /root/harness and mc_init built its whole state tree there. So the
# copy gets the same default-root rewrite the lane gets, and the rewrite is itself
# asserted: a sed that silently matched nothing would put the write back.
#   TWO FILES SINCE BH-684. bin/lib/merge-conductor-lib.sh is a shim that states
#   MC_H before its module loop, and bin/lib/mc/log.sh — which the loop sources —
#   states it again and derives every other MC_* path from it. Rewriting only one
#   leaves the other resolving /root/harness, so BOTH are rewritten and BOTH
#   rewrites are asserted.
for MCF in "$BH/bin/lib/merge-conductor-lib.sh" "$BH/bin/lib/mc/log.sh"; do
  sed -i 's|^MC_H="${HARNESS:-/root/harness}"$|MC_H="${HARNESS:-'"$BH"'}"|' "$MCF"
  grep -q "HARNESS:-$BH" "$MCF" && ok \
    || bad "the default-root rewrite did not match ${MCF#$BH/} — section D would resolve the real /root/harness"
done
printf 'tproj o/tproj - - 2 box-tproj 100.0.0.9\n' > "$T/br-fleet.conf"
( env -u HARNESS FLEET_CONF="$T/br-fleet.conf" REPOS_ROOT="$T/br-repos" GH_TOKEN="" \
    bash "$BH/bin/blocked-resolver.sh" tproj ) > "$T/br.out" 2>"$T/br.err"
BR_RC=$?
[ "$BR_RC" = 0 ] && ok || bad "blocked-resolver.sh with no HARNESS in the environment exited $BR_RC: $(tail -5 "$T/br.err")"
grep -q 'unbound variable' "$T/br.err" && bad "blocked-resolver.sh died on an unbound HARNESS: $(grep 'unbound variable' "$T/br.err")" || ok
# The lane creates its own tree on startup; those directories under the scratch
# root are the witness that this really ran against the rewritten default and
# not against a live /root/harness.
[ -d "$BH/logs" ] && [ -d "$BH/state" ] && [ -d "$BH/locks" ] && ok \
  || bad "blocked-resolver.sh never reached its own startup mkdir — section D tested nothing"
# The SOURCED LIB has its own root, and it is the one that used to escape. The
# lane's own tree above proves nothing about mc_init, which mkdirs under MC_H.
# If the copied lib still defaulted to /root/harness this directory is absent
# (the lib built its tree somewhere else) and the run is a write into whatever
# harness the box has — which is the #388 shape.
[ -d "$BH/state/merge-conductor" ] && ok \
  || bad "mc_init never created state/merge-conductor under the scratch root — the copied lib resolved some other harness"

echo "no-harness-export-test: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]
