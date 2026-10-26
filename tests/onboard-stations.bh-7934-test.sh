#!/bin/bash
# tests/onboard-stations.bh-7934-test.sh — the onboarding station functions in
# bin/lib/onboard-stations.sh (BH-7934.1, ticket BH-7948).
#
# Each case sources the REAL lib in a fresh subshell, in its own scratch
# checkout $T/<case>/R with stub scripts (bin/fleet-conf.sh, bin/registry.sh,
# bin/render-crontab.sh, bin/box-for.sh) and PATH stubs (git, gh, ssh,
# hostname). Every stub appends "<name> <args>" to the case's own calls.log.
# The ssh stub runs the heredoc locally with /root/harness rewritten to the
# case's own fake box dir, so nothing reaches a real machine, a real registry,
# GitHub or the live /root/harness. Cases share no files and run in any order.
#
# What it pins: each obs_* function exists and calls its script with the
# expected args (register -> registry.sh add-project; clone ->
# bootstrap-machine.sh <p> --repos-only), and a stub that exits non-zero makes
# the function return non-zero WITHOUT exiting the caller shell. C14 drives the
# production entry point, bin/load-project.sh, through the same lib.
#
# Run from anywhere: tests/onboard-stations.bh-7934-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
LIB="$DIR/bin/lib/onboard-stations.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL $1"; }
has()   { if grep -qF -- "$3" <<<"$2"; then ok "$1"; else bad "$1: no '$3' in: $2"; fi; }
line()  { if grep -qxF -- "$3" <<<"$2"; then ok "$1"; else bad "$1: no line '$3' in: $2"; fi; }
hasnt() { if grep -qF -- "$3" <<<"$2"; then bad "$1: unexpected '$3' in: $2"; else ok "$1"; fi; }
eq()    { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: got '$2' want '$3'"; fi; }
REAL_BASH=$(command -v bash); export REAL_BASH

# mk_case <name>: a scratch checkout $T/<name>/R, its stubs, and a fake box dir
# $T/<name>/boxh standing in for /root/harness on the box.
mk_case() {
  local C="$T/$1"
  mkdir -p "$C/R/bin/lib" "$C/R/prompts" "$C/stub" "$C/boxh/bin" "$C/boxh/env"
  : > "$C/calls.log"; : > "$C/ssh.log"
  ( cd "$DIR" && scratch_install_closure bin/lib/cron-lines.sh "$C/R" ) >/dev/null \
    || { bad "$1 could not install bin/lib/cron-lines.sh"; return 1; }
  cp "$DIR/prompts/TEMPLATE-GH.md" "$C/R/prompts/"
  : > "$C/R/fleet.conf"
  # bin/fleet-conf.sh: `repo` answers FC_REPO_RC (1 = no row), `offset` prints 1
  # (or fails with FC_OFF_RC), the box's tailnet ip is 192.0.2.7.
  cat > "$C/R/bin/fleet-conf.sh" <<'S'
#!/bin/bash
echo "fleet-conf.sh $*" >> "$CALLS"
case "$*" in
  --projects) exit 0 ;;
  --tailnet-ip-of-box*) echo 192.0.2.7 ;;
  *" repo") exit "${FC_REPO_RC:-1}" ;;
  *" offset") [ "${FC_OFF_RC:-0}" = 0 ] || exit "$FC_OFF_RC"; echo 1 ;;
esac
S
  cat > "$C/R/bin/registry.sh" <<'S'
#!/bin/bash
echo "registry.sh $*" >> "$CALLS"
exit "${REG_RC:-0}"
S
  cat > "$C/R/bin/box-for.sh" <<'S'
#!/bin/bash
echo "box-for.sh $*" >> "$CALLS"
S
  cat > "$C/R/bin/render-crontab.sh" <<'S'
#!/bin/bash
echo "render-crontab.sh $*" >> "$CALLS"
# A fixed line for the fixture project: the real script reads fleet.conf by
# box id, never the ambient $PROJECT (the C11 count must not depend on it).
echo "*/5 * * * * run newp"
S
  # git: every verb logs; commit answers GIT_COMMIT_RC, ALL verbs answer
  # GIT_ALL_RC when it is set. The tree always looks dirty and HEAD = origin.
  cat > "$C/stub/git" <<'S'
#!/bin/bash
echo "git $*" >> "$CALLS"
[ -z "${GIT_ALL_RC:-}" ] || exit "$GIT_ALL_RC"
case "$1" in
  diff) exit 1 ;;
  status) echo " M fleet.conf" ;;
  commit) exit "${GIT_COMMIT_RC:-0}" ;;
  rev-parse) echo abc123 ;;
esac
exit 0
S
  cat > "$C/stub/gh" <<'S'
#!/bin/bash
echo "gh $*" >> "$CALLS"
exit "${GH_RC:-0}"
S
  # hostname: never the target box, unless HOSTNAME_STUB says so.
  cat > "$C/stub/hostname" <<'S'
#!/bin/bash
echo "${HOSTNAME_STUB:-not-the-box}"
S
  # ssh: logs its args, exits SSH_RC when set, else drops its options and runs
  # the heredoc as the box would, with /root/harness rewritten to this case's
  # fake box dir.
  cat > "$C/stub/ssh" <<'S'
#!/bin/bash
echo "ssh $*" >> "$SSH_LOG"
[ -z "${SSH_RC:-}" ] || { cat >/dev/null; exit "$SSH_RC"; }
while [ "${1:-}" = -o ]; do shift 2; done
shift                       # root@<box>
shift 3                     # bash -s --
sed "s#/root/harness#$BOXH#g" | "$REAL_BASH" -s -- "$@"
S
  cat > "$C/boxh/bin/bootstrap-machine.sh" <<'S'
#!/bin/bash
echo "bootstrap-machine.sh $* REGISTRY_SOURCE=${REGISTRY_SOURCE:-}" >> "$CALLS"
exit "${BOOT_STUB_RC:-0}"
S
  chmod +x "$C/R/bin/"*.sh "$C/stub/"* "$C/boxh/bin/"*.sh
}

# run_case <name> <code>: source the real lib in a fresh subshell inside the
# case's checkout and eval <code>. Prints the combined output.
run_case() {
  local C="$T/$1"
  (
    cd "$C/R" || exit 99
    export CALLS="$C/calls.log" SSH_LOG="$C/ssh.log" BOXH="$C/boxh"
    PATH="$C/stub:$PATH"
    ROOT="$C/R"
    PROJECT=newp SLUG=Acme/newp REPO=Acme/newp PROD=- BOX=zzz-box PREFIX=NP BASE=main
    HARNESS_REPO=o/h
    unset REGISTRY_SOURCE REGISTRY_ADMIN_TOKEN GH_TOKEN FLY QUEUE CONTEXT_FILE PREFIX_LC REG_MODE
    # shellcheck source=bin/lib/onboard-stations.sh
    . "$LIB" || { echo "source failed"; exit 98; }
    eval "$2"
  ) 2>&1
}

# C1 a source under set -u prints nothing, and the five functions exist.
mk_case c1
out=$(run_case c1 'set -u; echo "srcout=[$( . "$LIB" 2>&1 )]"; for f in obs_register obs_prompt obs_label obs_box obs_clone; do declare -F "$f" >/dev/null && echo "def $f"; done')
has "C1 a source prints nothing" "$out" "srcout=[]"
for f in obs_register obs_prompt obs_label obs_box obs_clone; do has "C1 $f is defined" "$out" "def $f"; done

# C2 register, db mode: registry.sh add-project with the derived offset.
mk_case c2
out=$(run_case c2 'export REGISTRY_SOURCE=db REGISTRY_ADMIN_TOKEN=tok-fixture-1; obs_register; echo "rc=$? mode=$REG_MODE"')
line "C2 register db returns 0" "$out" "rc=0 mode=db"
has "C2 add-project args" "$(cat "$T/c2/calls.log")" "registry.sh add-project newp --repo Acme/newp --prod - --offset 1 --box zzz-box"
has "C2 prints the registry line" "$out" "registry: added (newp offset=1 box=zzz-box)"
eq  "C2 fleet.conf untouched in db mode" "$(wc -c < "$T/c2/R/fleet.conf" | tr -d ' ')" "0"

# C3 register, db mode, no token: FATAL, rc 1, no registry write, caller alive.
mk_case c3
out=$(run_case c3 'export REGISTRY_SOURCE=db; obs_register || echo "rc=$?"; echo alive')
line "C3 rc 1" "$out" "rc=1"
has "C3 FATAL line" "$out" "FATAL: REGISTRY_SOURCE=db and REGISTRY_ADMIN_TOKEN is unset"
hasnt "C3 no registry.sh call" "$(cat "$T/c3/calls.log")" "registry.sh"
has "C3 caller shell not exited" "$out" "alive"

# C4 register, registry.sh exits 1: rc 1, FATAL, caller still alive.
mk_case c4
out=$(run_case c4 'export REGISTRY_SOURCE=db REGISTRY_ADMIN_TOKEN=tok-fixture-1 REG_RC=1; obs_register || echo "rc=$?"; echo alive')
line "C4 rc 1" "$out" "rc=1"
has "C4 FATAL line" "$out" "FATAL: bin/registry.sh add-project newp failed"
has "C4 caller shell not exited" "$out" "alive"

# C5 register, file mode: one 7-column row, and every near miss of "db"
# (DB, "db ", empty, unset) stays file mode.
for v in DB "db " "" UNSET; do
  c="c5-$(printf '%s' "$v" | tr -c 'A-Za-z' '_')"
  mk_case "$c"
  if [ "$v" = UNSET ]; then set_mode=''; else set_mode="export REGISTRY_SOURCE='$v';"; fi
  out=$(run_case "$c" "$set_mode obs_register; echo \"rc=\$? mode=\$REG_MODE\"")
  line "C5 [$v] rc 0 in file mode" "$out" "rc=0 mode=file"
  has "C5 [$v] prints the fleet.conf line" "$out" "fleet.conf: added (newp offset=1 box=zzz-box)"
  hasnt "C5 [$v] no registry.sh call" "$(cat "$T/$c/calls.log")" "registry.sh"
done
row=$(cat "$T/c5-DB/R/fleet.conf")
eq  "C5 the row has 7 columns" "$(awk '{print NF}' <<<"$row")" "7"
eq  "C5 the 7th column is the box's tailnet ip" "$(awk '{print $7}' <<<"$row")" "192.0.2.7"

# C6 register, the row exists: skip, no add-project.
mk_case c6
out=$(run_case c6 'export REGISTRY_SOURCE=db REGISTRY_ADMIN_TOKEN=tok-fixture-1 FC_REPO_RC=0; obs_register; echo "rc=$?"')
line "C6 rc 0" "$out" "rc=0"
has "C6 skip line" "$out" "fleet.conf row exists — skipping"
hasnt "C6 no add-project" "$(cat "$T/c6/calls.log")" "add-project"

# C7 clone: bootstrap-machine.sh <p> --repos-only on the box over ssh; db mode
# reaches the box.
mk_case c7
out=$(run_case c7 'export REGISTRY_SOURCE=db; obs_clone; echo "rc=$?"')
line "C7 rc 0" "$out" "rc=0"
has "C7 header" "$out" "== clone: newp on zzz-box =="
has "C7 bootstrap --repos-only" "$(cat "$T/c7/calls.log")" "bootstrap-machine.sh newp --repos-only REGISTRY_SOURCE=db"
has "C7 ssh to the box" "$(cat "$T/c7/ssh.log")" "root@zzz-box"
hasnt "C7 not run locally" "$out" "target box is THIS machine"

# C8 clone, bootstrap exits 1: rc non-zero, FATAL, caller alive.
mk_case c8
out=$(run_case c8 'export BOOT_STUB_RC=1; obs_clone || echo "rc=$?"; echo alive')
line "C8 rc 1" "$out" "rc=1"
has "C8 FATAL line" "$out" "FATAL: clone on zzz-box exited 1"
has "C8 caller shell not exited" "$out" "alive"

# C9 box, ssh exits 7: rc 7 (the remote's own), FATAL, caller alive.
mk_case c9
out=$(run_case c9 'export SSH_RC=7; obs_box || echo "rc=$?"; echo alive')
line "C9 rc is the remote rc" "$out" "rc=7"
has "C9 FATAL line" "$out" "FATAL: bootstrap block on zzz-box exited 7"
has "C9 caller shell not exited" "$out" "alive"
has "C9 box args" "$(cat "$T/c9/ssh.log")" "root@zzz-box bash -s -- newp - NP main o/h file"

# C9b box, happy path through the ssh stub: the env stub is written on the box
# and the full bootstrap runs (no --repos-only).
mk_case c9b
: > "$T/c9b/boxh/env/global.env"
mkdir -p "$T/c9b/boxh-checkout/.git" "$T/c9b/boxh-checkout/prompts" "$T/c9b/boxh/prompts"
echo "newp x" > "$T/c9b/boxh-checkout/fleet.conf"
: > "$T/c9b/boxh-checkout/prompts/newp.md"; : > "$T/c9b/boxh/prompts/newp.md"
printf '#!/bin/bash\nexit 0\n' > "$T/c9b/boxh/bin/harness-sync.sh"; chmod +x "$T/c9b/boxh/bin/harness-sync.sh"
out=$(run_case c9b 'obs_box; echo "rc=$?"')
line "C9b rc 0" "$out" "rc=0"
has "C9b env stub written" "$out" "env stub written: $T/c9b/boxh/env/newp.env"
has "C9b full bootstrap" "$(cat "$T/c9b/calls.log")" "bootstrap-machine.sh newp REGISTRY_SOURCE="

# C10 label: gh rc 0 -> created, gh rc 1 -> exists, both return 0.
mk_case c10
out=$(run_case c10 'GH_TOKEN=tok-fixture-1 obs_label; echo "rc=$?"; GH_TOKEN=tok-fixture-1 GH_RC=1 obs_label; echo "rc2=$?"')
has "C10 label created" "$out" "label created"
has "C10 label exists" "$out" "label exists"
line "C10 rc 0 on create" "$out" "rc=0"
line "C10 rc 0 on exists" "$out" "rc2=0"
has "C10 gh args" "$(cat "$T/c10/calls.log")" "gh label create ai-build -R Acme/newp"

# C11 prompt: renders prompts/newp.md and publishes; a failed git commit returns
# 1 and never reaches the push, and the caller continues.
mk_case c11
out=$(run_case c11 'obs_prompt; echo "rc=$?"')
has "C11 rendered the prompt" "$out" "prompts/newp.md rendered"
has "C11 prompt file has the slug" "$(cat "$T/c11/R/prompts/newp.md")" "Acme/newp"
has "C11 crontab preview" "$out" "renders 1 line(s) for newp"
has "C11 publishes" "$out" "published abc123"
for v in "git add fleet.conf prompts/newp.md" "git commit" "git push -q"; do
  has "C11 git log has '$v'" "$(cat "$T/c11/calls.log")" "$v"
done
mk_case c11b
out=$(run_case c11b 'export GIT_COMMIT_RC=1; obs_prompt || echo "rc=$?"; echo alive')
line "C11b commit failure returns 1" "$out" "rc=1"
hasnt "C11b no push after a failed commit" "$(cat "$T/c11b/calls.log")" "git push"
has "C11b caller shell not exited" "$out" "alive"

# C12 the caller's own EXIT trap survives obs_prompt (no trap inside the lib),
# and the crontab preview temp file is removed.
mk_case c12
out=$(run_case c12 'export TMPDIR="'"$T"'/c12/tmp"; mkdir -p "$TMPDIR"; trap "echo caller-trap-fired" EXIT; obs_prompt >/dev/null; echo "rc=$?"; echo "tmp=$(ls -A "$TMPDIR" | wc -l | tr -d " ")"')
line "C12 obs_prompt rc 0" "$out" "rc=0"
has "C12 the caller's EXIT trap fires" "$out" "caller-trap-fired"
has "C12 the preview temp file is removed" "$out" "tmp=0"

# C13 local box: BOX = this hostname runs the block with a local bash, no ssh.
mk_case c13
cat > "$T/c13/stub/bash" <<'S'
#!/bin/bash
echo "bash $*" >> "$CALLS"
sed "s#/root/harness#$BOXH#g" | "$REAL_BASH" "$@"
S
chmod +x "$T/c13/stub/bash"
out=$(run_case c13 'export HOSTNAME_STUB=zzz-box; obs_clone; echo "rc=$?"')
has "C13 local-box line" "$out" "target box is THIS machine"
line "C13 rc 0" "$out" "rc=0"
has "C13 bootstrap --repos-only" "$(cat "$T/c13/calls.log")" "bootstrap-machine.sh newp --repos-only"
eq  "C13 no ssh call" "$(wc -c < "$T/c13/ssh.log" | tr -d ' ')" "0"

# C14 the production entry point: the real bin/load-project.sh sources the lib,
# runs the stations in order, and exits with the box block's OWN rc (7 here),
# not a flat 1. Same tree shape as tests/load-project-exit-code-test.sh: a copy
# of bin/, a real local git repo, network verbs and ssh stubbed.
C14="$T/c14"; mkdir -p "$C14/stub" "$C14/R/prompts"
REAL_GIT=$(command -v git); export REAL_GIT
cat > "$C14/stub/gh" <<'S'
#!/bin/bash
case "$*" in
  *defaultBranchRef.name*) echo main ;;
  "repo view"*)            echo "{}" ;;
  *)                       echo "[]" ;;
esac
exit 0
S
cat > "$C14/stub/git" <<'S'
#!/bin/bash
case "$1" in
  pull|push|fetch) exit 0 ;;
  rev-parse) case "$*" in *origin/*) exec "$REAL_GIT" rev-parse HEAD ;; esac ;;
esac
exec "$REAL_GIT" "$@"
S
cat > "$C14/stub/ssh" <<'S'
#!/bin/bash
cat >/dev/null
exit 7
S
printf '#!/bin/bash\necho not-the-box\n' > "$C14/stub/hostname"
chmod +x "$C14/stub/"*
cp -r "$DIR/bin" "$C14/R/bin"
cp "$DIR/prompts/TEMPLATE-GH.md" "$C14/R/prompts/"
: > "$C14/R/fleet.conf"
( cd "$C14/R" && "$REAL_GIT" init -q . && "$REAL_GIT" config user.email t@example.com \
  && "$REAL_GIT" config user.name t && "$REAL_GIT" add -A && "$REAL_GIT" commit -qm base ) >/dev/null 2>&1
out=$(cd "$C14/R" && PATH="$C14/stub:$PATH" REGISTRY_SOURCE=file bash bin/load-project.sh acme/widget --project widget --box zzz-box 2>&1)
rc=$?
eq  "C14 load-project.sh exits with the box block's rc" "$rc" "7"
prev=0
for l in "== registry ==" "fleet.conf: added (widget" "== prompt ==" "prompts/widget.md rendered" "== crontab ==" \
         "== commit + push ==" "published " "== ai-build label ==" "== box: zzz-box ==" \
         "FATAL: bootstrap block on zzz-box exited 7"; do
  n=$(grep -nF -- "$l" <<<"$out" | head -1 | cut -d: -f1)
  if [ -n "$n" ] && [ "$n" -gt "$prev" ]; then ok "C14 CLI prints '$l' in order"; prev=$n
  else bad "C14 CLI prints '$l' in order (line '${n:-none}' after $prev): $out"; fi
done
hasnt "C14 a failed box never prints LOADED" "$out" "== LOADED"
has "C14 the row was committed" "$(cd "$C14/R" && "$REAL_GIT" show --stat HEAD)" "fleet.conf"

echo "onboard-stations: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
