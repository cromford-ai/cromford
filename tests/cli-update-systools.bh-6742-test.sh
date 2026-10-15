#!/bin/bash
# tests/cli-update-systools.bh-6742-test.sh — bin/cli-update.sh also keeps
# flyctl and gh current (BH-6742), with stub binaries, never the real apt.
#
#   F1  flyctl upgrades: CSV row 0.4.102 -> 0.4.117 ok=1, the previous binary
#       kept at <bin>.prev and still answers 0.4.102
#   F2  a no-op day: ok=1, no .prev written
#   F3  `flyctl version upgrade` fails: the old binary stays, ok=1, note
#       upgrade-failed
#   F4  the upgrade leaves a binary that cannot run: the previous one is put
#       back (restored-prev), exit 0
#   F5  the upgrade goes OLDER: the previous one is put back
#   F6  no flyctl on the box: no flyctl row
#   G1  gh with no GitHub repo: the key is fetched, github-cli.list names it
#       (signed-by), apt-get update reads ONLY that list, gh 2.45.0 -> 2.81.0
#   G2  the repo is already there: no key fetch
#   G3  apt-get install fails: gh stays 2.45.0, ok=1, note install-failed
#   G4  the install leaves gh missing: `apt-get install gh=<old dpkg version>`
#       puts it back (restored-prev)
#   G5  the key fetch fails: no list written, apt-get never called
#   G6  no apt-get on the box: no gh row
#   S0  a scratch box (CLI_UPDATE_HOME set) with no CLI_UPDATE_SYS_TOOLS never
#       calls apt-get or flyctl
# Run from anywhere: tests/cli-update-systools.bh-6742-test.sh (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
BASE="$T"
# The machine's own tools, minus every one this suite stubs.
mkdir -p "$BASE/sysbin"
for f in /usr/bin/* /bin/*; do
  n=$(basename "$f")
  case "$n" in claude|codex|grok|npm|curl|flyctl|fly|gh|apt-get|apt|dpkg|dpkg-query) continue ;; esac
  [ -e "$BASE/sysbin/$n" ] || ln -s "$f" "$BASE/sysbin/$n" 2>/dev/null
done

# write_fly <file> <version> — a flyctl stub. `version upgrade` rewrites the
# file through a temp + mv (a new inode, as the real self-update does), per
# FLY_MODE: up (-> FLY_NEW), down (-> 0.4.90), break (a file that cannot
# answer --version), fail (rc 1, no change), anything else (no change).
write_fly() {
  cat > "$1.w" <<EOF
#!/bin/bash
V=$2
case "\$1" in
  --version) echo "flyctl v\$V linux/amd64 Commit: x" ;;
  version)
    [ "\${2:-}" = upgrade ] || exit 0
    echo "upgrade" >> "\$FLY_CALLS"
    case "\${FLY_MODE:-none}" in
      up)    sed "s/^V=.*/V=\$FLY_NEW/" "\$0" > "\$0.n" && chmod +x "\$0.n" && mv -f "\$0.n" "\$0" ;;
      down)  sed "s/^V=.*/V=0.4.90/" "\$0" > "\$0.n" && chmod +x "\$0.n" && mv -f "\$0.n" "\$0" ;;
      break) printf '#!/bin/bash\nexit 3\n' > "\$0.n" && chmod +x "\$0.n" && mv -f "\$0.n" "\$0" ;;
      fail)  exit 1 ;;
    esac ;;
esac
exit 0
EOF
  chmod +x "$1.w"; mv -f "$1.w" "$1"
}

# new_box — a scratch harness, home, apt dir and stub bin dir.
new_box() {
  local B; B=$(mktemp -d "$BASE/box-XXXXXX")
  mkdir -p "$B/harness/logs" "$B/harness/state" "$B/harness/env" "$B/home/.fly/bin" "$B/etc/apt" "$B/fakebin"
  echo testbox > "$B/harness/state/box-id"
  : > "$B/harness/env/global.env"
  : > "$B/apt-calls"; : > "$B/curl-calls"; : > "$B/fly-calls"
  echo 2.45.0 > "$B/gh.ver"
  # gh: answers the version in gh.ver; gone when the file is gone.
  cat > "$B/fakebin/gh" <<EOF
#!/bin/bash
[ -s "$B/gh.ver" ] || exit 127
echo "gh version \$(cat "$B/gh.ver") (fixture)"
EOF
  chmod +x "$B/fakebin/gh"
  # apt-get: logs argv; `install ... gh` per GH_MODE; `install gh=<v>` restores.
  cat > "$B/fakebin/apt-get" <<EOF
#!/bin/bash
echo "\$*" >> "$B/apt-calls"
case " \$* " in
  *" update "*) exit "\${APT_UPDATE_RC:-0}" ;;
  *" gh=2.45.0-1ubuntu0.3"*) echo 2.45.0 > "$B/gh.ver"; exit 0 ;;
  *" install "*)
    case "\${GH_MODE:-up}" in
      up)    echo 2.81.0 > "$B/gh.ver" ;;
      fail)  exit 100 ;;
      break) : > "$B/gh.ver" ;;
    esac ;;
esac
exit 0
EOF
  chmod +x "$B/fakebin/apt-get"
  printf '#!/bin/bash\necho 2.45.0-1ubuntu0.3\n' > "$B/fakebin/dpkg-query"
  printf '#!/bin/bash\necho amd64\n' > "$B/fakebin/dpkg"
  # curl: logs argv; writes the -o file unless CURL_RC says it fails.
  cat > "$B/fakebin/curl" <<EOF
#!/bin/bash
echo "\$*" >> "$B/curl-calls"
[ "\${CURL_RC:-0}" = 0 ] || exit "\$CURL_RC"
o=""; while [ \$# -gt 0 ]; do [ "\$1" = -o ] && o="\$2"; shift; done
[ -n "\$o" ] && echo "fixture-key" > "\$o"
exit 0
EOF
  chmod +x "$B/fakebin/curl" "$B/fakebin/dpkg-query" "$B/fakebin/dpkg"
  write_fly "$B/home/.fly/bin/flyctl" 0.4.102
  echo "$B"
}

# run <box> [VAR=value...] — the real bin/cli-update.sh, runner CLIs off.
run() {
  local B="$1"; shift
  OUT=$(cd "$B" && env -i PATH="$B/fakebin:$BASE/sysbin" HOME="$B/home" \
        HARNESS="$B/harness" CLI_UPDATE_HOME="$B/home" CLI_UPDATE_CLIS=" " \
        CLI_UPDATE_JOBS_CLIENT=/nonexistent CLI_UPDATE_APT_ETC="$B/etc/apt" \
        FLY_CALLS="$B/fly-calls" FLY_NEW=0.4.117 "$@" \
        bash "$DIR/bin/cli-update.sh" 2>"$B/stderr"); RC=$?
}
row() { grep ",$2," "$1/harness/logs/cli-versions.csv" | tail -1; }   # row <box> <tool>

echo "F1: flyctl upgrades, the previous binary is kept"
B=$(new_box); run "$B" CLI_UPDATE_SYS_TOOLS=flyctl FLY_MODE=up
R=$(row "$B" flyctl)
[ "$RC" = 0 ] && ok "F1 exit 0" || bad "F1 rc $RC: $OUT $(cat "$B/stderr")"
[ "$(cut -d, -f4,5,6,7 <<<"$R")" = "0.4.102,0.4.117,upgrade,1" ] && ok "F1 CSV row 0.4.102 -> 0.4.117 upgrade ok=1" || bad "F1 row: $R"
grep -q 'prev-kept' <<<"$R" && ok "F1 note prev-kept" || bad "F1 note: $R"
[ "$("$B/home/.fly/bin/flyctl.prev" --version 2>/dev/null | grep -oE '[0-9]+(\.[0-9]+)+' | head -1)" = 0.4.102 ] \
  && ok "F1 <bin>.prev still answers 0.4.102" || bad "F1 prev: $(ls -la "$B/home/.fly/bin")"
grep -q '^flyctl 0.4.102 -> 0.4.117 method=upgrade ok=1' <<<"$OUT" && ok "F1 stdout line" || bad "F1 stdout: $OUT"

echo "F2: a no-op day keeps no new .prev"
B=$(new_box); run "$B" CLI_UPDATE_SYS_TOOLS=flyctl FLY_MODE=none
[ "$(cut -d, -f4,5,7 <<<"$(row "$B" flyctl)")" = "0.4.102,0.4.102,1" ] && ok "F2 row 0.4.102 -> 0.4.102 ok=1" || bad "F2 row: $(row "$B" flyctl)"
[ ! -e "$B/home/.fly/bin/flyctl.prev" ] && [ ! -e "$B/home/.fly/bin/flyctl.prev.tmp" ] && ok "F2 no .prev, no temp copy left" \
  || bad "F2 files: $(ls "$B/home/.fly/bin")"

echo "F3: the upgrade command fails"
B=$(new_box); run "$B" CLI_UPDATE_SYS_TOOLS=flyctl FLY_MODE=fail
R=$(row "$B" flyctl)
[ "$RC" = 0 ] && [ "$(cut -d, -f4,5,7 <<<"$R")" = "0.4.102,0.4.102,1" ] && grep -q upgrade-failed <<<"$R" \
  && ok "F3 old binary kept, ok=1, note upgrade-failed" || bad "F3 rc $RC row: $R"

echo "F4: the upgrade leaves a binary that cannot run"
B=$(new_box); run "$B" CLI_UPDATE_SYS_TOOLS=flyctl FLY_MODE=break
R=$(row "$B" flyctl)
[ "$RC" = 0 ] && [ "$(cut -d, -f4,5,7 <<<"$R")" = "0.4.102,0.4.102,1" ] && grep -q restored-prev <<<"$R" \
  && ok "F4 the previous binary is put back" || bad "F4 rc $RC row: $R"
"$B/home/.fly/bin/flyctl" --version 2>/dev/null | grep -q 0.4.102 && ok "F4 flyctl answers 0.4.102 again" || bad "F4 flyctl does not run"

echo "F5: the upgrade goes older"
B=$(new_box); run "$B" CLI_UPDATE_SYS_TOOLS=flyctl FLY_MODE=down
R=$(row "$B" flyctl)
[ "$(cut -d, -f5,7 <<<"$R")" = "0.4.102,1" ] && grep -q restored-prev <<<"$R" && ok "F5 restored to 0.4.102" || bad "F5 row: $R"

echo "F6: no flyctl on the box"
B=$(new_box); rm -f "$B/home/.fly/bin/flyctl"; run "$B" CLI_UPDATE_SYS_TOOLS=flyctl
[ -z "$(row "$B" flyctl)" ] && [ "$RC" = 0 ] && ok "F6 no flyctl row, exit 0" || bad "F6 rc $RC row: $(row "$B" flyctl)"

echo "G1: gh from GitHub's apt repo"
B=$(new_box); run "$B" CLI_UPDATE_SYS_TOOLS=gh GH_MODE=up
R=$(row "$B" gh)
[ "$RC" = 0 ] && [ "$(cut -d, -f4,5,6,7 <<<"$R")" = "2.45.0,2.81.0,apt,1" ] && ok "G1 CSV row 2.45.0 -> 2.81.0 apt ok=1" || bad "G1 rc $RC row: $R"
grep -q 'cli.github.com/packages/githubcli-archive-keyring.gpg' "$B/curl-calls" && ok "G1 the key comes from cli.github.com" || bad "G1 curl: $(cat "$B/curl-calls")"
L="$B/etc/apt/sources.list.d/github-cli.list"
[ "$(cat "$L" 2>/dev/null)" = "deb [arch=amd64 signed-by=$B/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" ] \
  && ok "G1 github-cli.list names the keyring" || bad "G1 list: $(cat "$L" 2>&1)"
grep -q "^update -o Dir::Etc::sourcelist=$L -o Dir::Etc::sourceparts=- " "$B/apt-calls" && ok "G1 apt-get update reads only the GitHub list" \
  || bad "G1 apt calls: $(cat "$B/apt-calls")"
grep -q 'install -y .* gh$' "$B/apt-calls" && ok "G1 apt-get install gh" || bad "G1 install: $(cat "$B/apt-calls")"
grep -q 'repo-added' <<<"$R" && ok "G1 note repo-added" || bad "G1 note: $R"

echo "G2: the repo is already there"
: > "$B/curl-calls"; echo 2.81.0 > "$B/gh.ver"; run "$B" CLI_UPDATE_SYS_TOOLS=gh GH_MODE=up
[ ! -s "$B/curl-calls" ] && ok "G2 no second key fetch" || bad "G2 curl: $(cat "$B/curl-calls")"
! grep -q repo-added <<<"$(row "$B" gh)" && ok "G2 no repo-added note" || bad "G2 row: $(row "$B" gh)"

echo "G3: apt-get install fails"
B=$(new_box); run "$B" CLI_UPDATE_SYS_TOOLS=gh GH_MODE=fail
R=$(row "$B" gh)
[ "$RC" = 0 ] && [ "$(cut -d, -f4,5,7 <<<"$R")" = "2.45.0,2.45.0,1" ] && grep -q install-failed <<<"$R" \
  && ok "G3 gh stays 2.45.0, ok=1, install-failed" || bad "G3 rc $RC row: $R"

echo "G4: the install leaves gh missing"
B=$(new_box); run "$B" CLI_UPDATE_SYS_TOOLS=gh GH_MODE=break
R=$(row "$B" gh)
grep -q 'install -y --allow-downgrades gh=2.45.0-1ubuntu0.3' "$B/apt-calls" && ok "G4 the old dpkg version is reinstalled" \
  || bad "G4 apt calls: $(cat "$B/apt-calls")"
[ "$RC" = 0 ] && [ "$(cut -d, -f5,7 <<<"$R")" = "2.45.0,1" ] && grep -q restored-prev <<<"$R" && ok "G4 gh is 2.45.0 again, restored-prev" \
  || bad "G4 rc $RC row: $R"

echo "G5: the key fetch fails"
B=$(new_box); run "$B" CLI_UPDATE_SYS_TOOLS=gh CURL_RC=22
[ ! -e "$B/etc/apt/sources.list.d/github-cli.list" ] && [ ! -s "$B/apt-calls" ] && ok "G5 no list, apt-get never called" \
  || bad "G5 list/apt: $(ls "$B/etc/apt/sources.list.d" 2>&1) / $(cat "$B/apt-calls")"
grep -q key-fetch-failed <<<"$(row "$B" gh)" && ok "G5 note key-fetch-failed" || bad "G5 row: $(row "$B" gh)"

echo "G6: no apt-get on the box"
B=$(new_box); rm -f "$B/fakebin/apt-get"; run "$B" CLI_UPDATE_SYS_TOOLS=gh
[ -z "$(row "$B" gh)" ] && [ "$RC" = 0 ] && ok "G6 no gh row, exit 0" || bad "G6 rc $RC row: $(row "$B" gh)"

echo "S0: a scratch box without CLI_UPDATE_SYS_TOOLS touches no system tool"
B=$(new_box); run "$B" FLY_MODE=up GH_MODE=up
[ ! -s "$B/apt-calls" ] && [ ! -s "$B/fly-calls" ] && [ -z "$(row "$B" gh)$(row "$B" flyctl)" ] \
  && ok "S0 no apt-get, no flyctl call, no row" || bad "S0 apt: $(cat "$B/apt-calls") fly: $(cat "$B/fly-calls")"

echo "cli-update-systools.bh-6742: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
