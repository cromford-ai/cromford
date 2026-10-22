#!/bin/bash
# tests/load-project-db.bh-5650-test.sh — BH-5650 (T5): bin/load-project.sh in
# REGISTRY_SOURCE=db writes the project row through bin/registry.sh add-project
# (the REAL harness-jobs worker over SQLite, tests/lib/registry-fixture.bh-5650.sh)
# and never appends to or commits fleet.conf. File mode is unchanged.
#
#   L1  db mode: load-project.sh Acme/newp --box box-small
#       --no-bootstrap exits 0, and a re-run is "row exists" with no write
#   L2  GET /api/registry has newp with repo Acme/newp, box box-small,
#       and the offset fleet-conf.sh reads back
#   L3  fleet.conf bytes unchanged, `git log -- fleet.conf` count unchanged
#   L4  the HEAD commit carries the prompt and does not touch fleet.conf
#   L5  file mode on a fresh scratch appends the row exactly as before, makes
#       no registry call, and commits fleet.conf with the prompt
#   L6  db mode with REGISTRY_ADMIN_TOKEN unset: rc != 0, no commit, no row,
#       no write call, no prompt, fleet.conf unchanged
#   L7  db mode with a wrong admin token (403): rc != 0, no commit, no row
#   L8  the box block gets the mode as its 6th arg; in db mode it exports
#       REGISTRY_SOURCE=db and needs no fleet.conf in the box checkout; in file
#       mode (or with 5 args) a checkout without the row is still FATAL
#
# Nothing touches a real box: gh, ssh, hostname and the network verbs of git
# are stubs, and every checkout lives in $T. Run from anywhere (exit 0 = pass).
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
"$DIR/bin/llm-sites-build.sh" --compose --repo "$DIR" >/dev/null || { echo "FAIL: cannot compose catalog/llm-sites.json"; exit 1; }
. "$DIR/tests/lib/registry-fixture.bh-5650.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: got '$2' want '$3'"; fi; }

rfx_setup; R=$?
[ "$R" -ne 3 ] || { echo "SKIP: node:sqlite is not available"; exit 0; }
[ "$R" -eq 0 ] || { echo "FAIL: the fixture registry could not be seeded"; exit 1; }

REAL_GIT=$(command -v git); export REAL_GIT

# ── stubs: gh, ssh, hostname, and the network verbs of git ──────────────────
mkdir -p "$T/stub"
cat > "$T/stub/gh" <<'STUB'
#!/bin/bash
case "$*" in
  *defaultBranchRef.name*) echo main ;;
  "repo view"*)            echo "{}" ;;
  *)                       echo "[]" ;;
esac
exit 0
STUB
cat > "$T/stub/git" <<'STUB'
#!/bin/bash
# Only pull/push/fetch are faked: everything else is the REAL git against the
# scratch checkout, so the commit the loader makes is a real commit.
case "$1" in
  pull|push|fetch) exit 0 ;;
  rev-parse) case "$*" in *origin/*) exec "$REAL_GIT" rev-parse HEAD ;; esac ;;
esac
exec "$REAL_GIT" "$@"
STUB
cat > "$T/stub/ssh" <<STUB
#!/bin/bash
printf '%s\n' "\$*" > "$T/ssh.args"
cat > "$T/ssh.script"
exit 0
STUB
printf '#!/bin/bash\necho zzz-fixture-host\n' > "$T/stub/hostname"
chmod +x "$T/stub/gh" "$T/stub/git" "$T/stub/ssh" "$T/stub/hostname"

mkrepo() { # mkrepo <dir> — a scratch cromford checkout with this tree's fleet.conf
  local R="$1" s
  mkdir -p "$R/prompts"
  for s in bin/load-project.sh bin/fleet-conf.sh bin/box-for.sh bin/registry.sh bin/render-crontab.sh; do
    scratch_install_closure "$s" "$R" >/dev/null || return 1
  done
  cp "$DIR/prompts/TEMPLATE-GH.md" "$R/prompts/TEMPLATE-GH.md"
  cp "$DIR/fleet.conf" "$R/fleet.conf"
  cp "$DIR/fleet.conf" "$R.fleet.conf.orig"
  (
    cd "$R" || exit 1
    "$REAL_GIT" init -q .
    "$REAL_GIT" config user.email t@t
    "$REAL_GIT" config user.name t
    "$REAL_GIT" add -A
    "$REAL_GIT" commit -qm base
  ) >/dev/null 2>&1
}

# dbload <repo> <out> [args...] — the real loader in db mode against the fixture.
dbload() {
  local R="$1" O="$2"; shift 2
  ( cd "$R" && PATH="$T/stub:$PATH" rfx_db bash bin/load-project.sh "$@" ) >"$O" 2>&1
}
head_of() { "$REAL_GIT" -C "$1" rev-parse HEAD; }
conf_commits() { "$REAL_GIT" -C "$1" log --oneline -- fleet.conf | wc -l | tr -d ' '; }
proj_rows() { rfx_q "SELECT COUNT(*) AS n FROM registry_projects WHERE project='$1'" | jq '.[0].n'; }
writes() { grep -c -- '-X POST' "$T/curl.log"; }

# ── L1 ─────────────────────────────────────────────────────────────────────
mkrepo "$T/d" || { echo "FAIL: scratch checkout"; exit 1; }
H0=$(head_of "$T/d"); C0=$(conf_commits "$T/d")
eq "precondition: newp is not in the seeded registry" "$(proj_rows newp)" "0"
dbload "$T/d" "$T/l1.out" Acme/newp --box box-small --no-bootstrap; R=$?
eq "L1 rc" "$R" "0"
[ "$R" = 0 ] || cat "$T/l1.out"
grep -q '^registry: add-project changed=1 version=' "$T/l1.out" && ok \
  || bad "L1 the loader must print registry.sh's add-project line"
eq "L1 one write call" "$(writes)" "1"

# ── L2 ─────────────────────────────────────────────────────────────────────
rfx_db curl -sS -H 'authorization: Bearer fixture-secret' https://jobs.test/api/registry > "$T/reg.json"
jq -e '.projects[] | select(.project == "newp")' "$T/reg.json" > "$T/newp.json" && ok || bad "L2 GET /api/registry has no newp"
eq "L2 repo" "$(jq -r .repo "$T/newp.json")" "Acme/newp"
eq "L2 box"  "$(jq -r .box "$T/newp.json")" "box-small"
DBOFF=$(jq -r .cron_offset "$T/newp.json")
[[ "$DBOFF" =~ ^[0-9]$ ]] && ok || bad "L2 cron_offset '$DBOFF' is not 0-9"
eq "L2 fleet-conf.sh reads the row back" \
  "$(REGISTRY_CACHE_TTL_S=0 rfx_db "$T/d/bin/fleet-conf.sh" newp offset 2>/dev/null)" "$DBOFF"

# ── L3 ─────────────────────────────────────────────────────────────────────
cmp -s "$T/d/fleet.conf" "$T/d.fleet.conf.orig" && ok || bad "L3 fleet.conf bytes changed: $(diff "$T/d.fleet.conf.orig" "$T/d/fleet.conf" | head -3)"
eq "L3 commits touching fleet.conf" "$(conf_commits "$T/d")" "$C0"
eq "L3 fleet.conf is not dirty" "$("$REAL_GIT" -C "$T/d" status --porcelain -- fleet.conf)" ""

# ── L4 ─────────────────────────────────────────────────────────────────────
[ "$(head_of "$T/d")" != "$H0" ] && ok || bad "L4 db mode made no commit (the prompt still commits)"
"$REAL_GIT" -C "$T/d" show --name-only --format= HEAD > "$T/l4.files"
grep -qx 'prompts/newp.md' "$T/l4.files" && ok || bad "L4 HEAD does not carry prompts/newp.md: $(cat "$T/l4.files")"
grep -qx 'fleet.conf' "$T/l4.files" && bad "L4 HEAD touches fleet.conf" || ok

# L1b: a re-run finds the row and writes nothing.
H1=$(head_of "$T/d"); V1=$(rfx_q 'SELECT version FROM registry_meta' | jq '.[0].version')
dbload "$T/d" "$T/l1b.out" Acme/newp --box box-small --no-bootstrap; R=$?
eq "L1b re-run rc" "$R" "0"
grep -q 'row exists' "$T/l1b.out" && ok || bad "L1b the re-run must find the row: $(cat "$T/l1b.out")"
eq "L1b no second write" "$(writes)" "1"
eq "L1b version unchanged" "$(rfx_q 'SELECT version FROM registry_meta' | jq '.[0].version')" "$V1"
eq "L1b no new commit" "$(head_of "$T/d")" "$H1"

# ── L5: file mode, fresh scratch ───────────────────────────────────────────
mkrepo "$T/f" || { echo "FAIL: scratch checkout"; exit 1; }
CALLS=$(rfx_calls); C0=$(conf_commits "$T/f")
( cd "$T/f" && env -u REGISTRY_SOURCE PATH="$T/stub:$T/bin:$PATH" HARNESS="$T/hf" \
    bash bin/load-project.sh Acme/newp --box box-small --no-bootstrap ) >"$T/l5.out" 2>&1; R=$?
eq "L5 rc" "$R" "0"
[ "$R" = 0 ] || cat "$T/l5.out"
OFF=$(FLEET_CONF="$T/f/fleet.conf" "$T/f/bin/fleet-conf.sh" newp offset 2>/dev/null)
eq "L5 file mode picks the offset db mode picked" "$OFF" "$DBOFF"
# The row carries the box's tailnet address when the registry knows it
# (TEST-CHANGE, hotfix after 8a1d9bc7c: a 6-column row on small broke box-register).
SMALL_IP=$(FLEET_CONF="$T/f.fleet.conf.orig" "$T/f/bin/fleet-conf.sh" --tailnet-ip-of-box box-small 2>/dev/null)
[ -n "$SMALL_IP" ] && ok || bad "L5 precondition: the scratch registry knows the address of box-small"
{ cat "$T/f.fleet.conf.orig"
  printf '%-13s %-26s %-36s %-3s %-2s %s%s\n' newp Acme/newp - - "$OFF" box-small "${SMALL_IP:+ $SMALL_IP}"
} > "$T/l5.want"
cmp -s "$T/f/fleet.conf" "$T/l5.want" && ok || bad "L5 fleet.conf is not the old file plus the one row: $(diff "$T/l5.want" "$T/f/fleet.conf" | head -4)"
eq "L5 no registry call" "$(rfx_calls)" "$CALLS"
eq "L5 one more commit touching fleet.conf" "$(conf_commits "$T/f")" "$((C0 + 1))"
"$REAL_GIT" -C "$T/f" show --name-only --format= HEAD | LC_ALL=C sort > "$T/l5.files"
eq "L5 HEAD files" "$(tr '\n' ' ' < "$T/l5.files")" "fleet.conf prompts/newp.md "
grep -q '^fleet.conf: added (newp offset=' "$T/l5.out" && ok || bad "L5 the file-mode line is gone"

# ── L6: db mode, REGISTRY_ADMIN_TOKEN unset ────────────────────────────────
# rfx_db supplies the fixture token when the variable is unset, so the run
# strips it with env -u: the loader sees no token at all.
H6=$(head_of "$T/d"); W6=$(writes)
( cd "$T/d" && PATH="$T/stub:$PATH" rfx_db env -u REGISTRY_ADMIN_TOKEN \
    bash bin/load-project.sh Acme/newr --box box-small --no-bootstrap ) >"$T/l6.out" 2>&1; R=$?
[ "$R" -ne 0 ] && ok || bad "L6 rc 0 with no REGISTRY_ADMIN_TOKEN"
grep -q 'FATAL.*REGISTRY_ADMIN_TOKEN' "$T/l6.out" && ok || bad "L6 the FATAL must name REGISTRY_ADMIN_TOKEN: $(cat "$T/l6.out")"
eq "L6 no row" "$(proj_rows newr)" "0"
eq "L6 no write call" "$(writes)" "$W6"
eq "L6 no new commit" "$(head_of "$T/d")" "$H6"
[ ! -e "$T/d/prompts/newr.md" ] && ok || bad "L6 a prompt was rendered"
cmp -s "$T/d/fleet.conf" "$T/d.fleet.conf.orig" && ok || bad "L6 fleet.conf changed (a fallback append)"

# ── L7: db mode, wrong admin token (the worker answers 403) ────────────────
H7=$(head_of "$T/d")
( cd "$T/d" && PATH="$T/stub:$PATH" REGISTRY_ADMIN_TOKEN=fixture-wrong-token rfx_db \
    bash bin/load-project.sh Acme/news --box box-small --no-bootstrap ) >"$T/l7.out" 2>&1; R=$?
[ "$R" -ne 0 ] && ok || bad "L7 rc 0 after a refused write"
grep -q '403' "$T/l7.out" && ok || bad "L7 the output must carry the 403: $(cat "$T/l7.out")"
# The write's own failure stops it, not only the read-back after it.
grep -q 'FATAL: bin/registry.sh add-project news failed' "$T/l7.out" && ok || bad "L7 the add-project failure is not the FATAL"
eq "L7 no row" "$(proj_rows news)" "0"
eq "L7 no new commit" "$(head_of "$T/d")" "$H7"
[ ! -e "$T/d/prompts/news.md" ] && ok || bad "L7 a prompt was rendered"
cmp -s "$T/d/fleet.conf" "$T/d.fleet.conf.orig" && ok || bad "L7 fleet.conf changed"

# ── L8: the box block ──────────────────────────────────────────────────────
# newp's row and prompt exist, so the loader goes straight to the box. The box
# name matches no hostname and no box-id, so RUN_ON_BOX is the ssh stub.
dbload "$T/d" "$T/l8.out" Acme/newp --box zzz-nobox-fixture; R=$?
eq "L8 loader rc" "$R" "0"
[ -s "$T/ssh.script" ] && ok || bad "L8 the box block never reached ssh: $(cat "$T/l8.out")"
read -ra SARGS < "$T/ssh.args"
# -o ConnectTimeout=15 root@<box> bash -s -- <6 block args>
eq "L8 ssh argc" "${#SARGS[@]}" "12"
eq "L8 6th block arg" "${SARGS[11]:-}" "db"
mkbox() { # mkbox <root> — a fake /root with a checkout that has NO fleet.conf
  mkdir -p "$1/harness/env" "$1/harness-checkout/.git" "$1/harness-checkout/bin" \
    "$1/harness-checkout/prompts" "$1/harness-checkout/catalog" "$1/harness-checkout/rules"
  : > "$1/harness/env/global.env"
  : > "$1/harness-checkout/prompts/newp.md"
  printf '#!/bin/bash\necho "REGISTRY_SOURCE=${REGISTRY_SOURCE:-unset}" >> "%s/boot.log"\n' "$1" \
    > "$1/harness-checkout/bin/bootstrap-machine.sh"
  chmod +x "$1/harness-checkout/bin/bootstrap-machine.sh"
}
runbox() { # runbox <root> <args...> — the captured block with /root/ moved to <root>
  local B="$1"; shift
  sed "s#/root/#$B/#g" "$T/ssh.script" > "$B.sh"
  PATH="$T/boxstub:$T/stub:$PATH" bash "$B.sh" "$@" > "$B.out" 2>&1
}
# On the box, git only pulls the checkout: a no-op here.
mkdir -p "$T/boxstub"; printf '#!/bin/bash\nexit 0\n' > "$T/boxstub/git"; chmod +x "$T/boxstub/git"
mkbox "$T/boxdb"
runbox "$T/boxdb" newp - NP main fixture/harness db; R=$?
eq "L8 db block rc" "$R" "0"
[ "$R" = 0 ] || cat "$T/boxdb.out"
eq "L8 db bootstrap ran with REGISTRY_SOURCE=db" "$(cat "$T/boxdb/boot.log" 2>/dev/null)" "REGISTRY_SOURCE=db"
[ ! -e "$T/boxdb/harness/fleet.conf" ] && ok || bad "L8 db block copied a fleet.conf"
for mode in file ""; do
  mkbox "$T/boxf$mode"
  runbox "$T/boxf$mode" newp - NP main fixture/harness ${mode:+"$mode"}; R=$?
  eq "L8 file block (mode '${mode:-<5 args>}') rc" "$R" "1"
  grep -q "not in the box checkout's fleet.conf" "$T/boxf$mode.out" && ok \
    || bad "L8 file block (mode '${mode:-<5 args>}') lost the checkout fleet.conf check: $(cat "$T/boxf$mode.out")"
  [ ! -e "$T/boxf$mode/boot.log" ] && ok || bad "L8 file block bootstrapped without a row"
done

echo "load-project-db.bh-5650-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
