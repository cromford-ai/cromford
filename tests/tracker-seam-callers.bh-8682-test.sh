#!/bin/bash
# tests/tracker-seam-callers.bh-8682-test.sh — BH-8682: bin/lib/ticket-state.sh
# and bin/merged-build-closeout.sh ask bin/lib/tracker.sh which tracker a
# project uses (tracker_kind, tracker_context). They never read fleet.conf
# column 4 themselves, so the BH-7919 ratchet stays green.
#
# The settings seam is a fake bin/jobs-client.sh: setting_get over a TSV
# (`<key> TAB <value>`, rc 2 = no row) and the two ledger verbs. curl and gh
# are PATH shims that log every call. gh always fails; curl answers only the
# one C7 board URL.
#
#   C1  fleet.conf `-`, no row: --project is accepted (rc 0 or 1, never 2)
#   C2  fleet.conf `-`, row tracker_adapter.<p>=linear: --project rc 2
#   C3  fleet.conf `-`, row =jira: --project rc 2
#   C4  fleet.conf /api/board, no row: --project rc 2
#   C5  fleet.conf /api/board, row =github-issues: --project is accepted (the
#       row is the authority, column 4 is only the fallback)
#   C6  no --project: of the C1-C4 projects only the C1 project is read
#   C7  tks_state on a board project reads <base><prefix>/tickets/<id>; with a
#       base and no token it is rc 1
#   C8  tks_state with row =linear: rc 1 and 0 curl calls
#   C9  the ratchet scan finds no direct call in the two files
#   V   0 vendor calls beyond the C7 fixture URL
#
#   HARNESS_TEST_SANDBOX=1 bash tests/tracker-seam-callers.bh-8682-test.sh   exit 0 = pass
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq missing"; exit 0; }

H="$T/h"
mkdir -p "$H/logs" "$H/state" "$H/env" "$T/tmp" "$T/shim"
for s in bin/merged-build-closeout.sh bin/lib/ticket-state.sh bin/fleet-conf.sh bin/internal-token-for.sh; do
  ( cd "$DIR" && scratch_install_closure "$s" "$H" ) >/dev/null || { echo "FAIL: could not install $s"; exit 1; }
done
mkdir -p "$H/bin/lib/jobs"; [ -e "$H/bin/lib/jobs/req.sh" ] || : > "$H/bin/lib/jobs/req.sh"
cat > "$H/bin/jobs-client.sh" <<'JC'
setting_get() {
  awk -F'\t' -v k="$1" '$1 == k { v = $2; f = 1 } END { if (!f) exit 2; print v }' "$SEAM_FX_SETTINGS"
}
job_ledger_get() { return 2; }
job_ledger_put() { return 0; }
JC
printf '#!/bin/bash\nexit 0\n' > "$H/bin/lane-alert.sh"; chmod +x "$H/bin/lane-alert.sh"
: > "$H/env/global.env"
cat > "$H/fleet.conf" <<'FC'
issues-os  Org/issues  https://issues.example  -           2  box-a
linear-os  Org/linear  https://linear.example  -           2  box-a
jira-os    Org/jira    https://jira.example    -           2  box-a
board-os   Org/board   https://board.example   /api/board  2  box-a
moved-os   Org/moved   https://moved.example   /api/board  2  box-a
FC
printf 'BOARD_OS_API_BASE=https://board.example/\nBOARD_OS_INTERNAL_API_TOKEN=tok-fixture-8682\n' > "$H/env/board-os.env"
printf 'MOVED_OS_API_BASE=https://moved.example\n' > "$H/env/moved-os.env"

: > "$T/vendor.log"
printf '#!/bin/bash\nprintf "gh %%s\\n" "$*" >> "%s"\nexit 7\n' "$T/vendor.log" > "$T/shim/gh"
cat > "$T/shim/curl" <<SH
#!/bin/bash
url=""; for a in "\$@"; do case "\$a" in http*) url="\$a" ;; esac; done
printf 'curl %s\n' "\$url" >> "$T/vendor.log"
case "\$url" in
  https://board.example/api/board/tickets/5) printf '{"ticket":{"id":"5","status":"done"}}\n' ;;
  *) echo "curl: (22) The requested URL returned error: 404" >&2; exit 22 ;;
esac
SH
chmod +x "$T/shim/gh" "$T/shim/curl"

SET="$T/settings.tsv"
export HARNESS="$H" FLEET_CONF="$H/fleet.conf" TMPDIR="$T/tmp" PATH="$T/shim:$PATH" GH_ETAG=0 SEAM_FX_SETTINGS="$SET"
export HARNESS_SECRET=fixture-secret JOBS_URL="" BOX_NAME=box-a
rows() { : > "$SET"; local kv; for kv in "$@"; do printf 'tracker_adapter.%s\t%s\n' "${kv%%=*}" "${kv#*=}" >> "$SET"; done; }
mbc() { bash "$H/bin/merged-build-closeout.sh" --since 2026-10-17T00:00:00Z "$@" > "$T/out.tsv" 2> "$T/err.txt"; echo $?; }

echo "merged-build-closeout picks projects by tracker_kind"
rows
rc=$(mbc --project issues-os)
[ "$rc" = 0 ] || [ "$rc" = 1 ] && ok "C1 fleet.conf -, no row: accepted (rc $rc)" || bad "C1 rc $rc: $(cat "$T/err.txt")"
rows linear-os=linear jira-os=jira moved-os=github-issues
rc=$(mbc --project linear-os)
[ "$rc" = 2 ] && grep -q 'tracker is not github-issues' "$T/err.txt" && ok "C2 row linear: rc 2" || bad "C2 rc $rc: $(cat "$T/err.txt")"
rc=$(mbc --project jira-os)
[ "$rc" = 2 ] && ok "C3 row jira: rc 2" || bad "C3 rc $rc: $(cat "$T/err.txt")"
rc=$(mbc --project board-os)
[ "$rc" = 2 ] && ok "C4 fleet.conf /api/board, no row: rc 2" || bad "C4 rc $rc: $(cat "$T/err.txt")"
rc=$(mbc --project moved-os)
[ "$rc" = 0 ] || [ "$rc" = 1 ] && ok "C5 fleet.conf /api/board, row github-issues: accepted (rc $rc)" || bad "C5 rc $rc: $(cat "$T/err.txt")"
rows linear-os=linear jira-os=jira
rc=$(mbc)
read_set=$(awk -F'\t' '$3 != "summary" { print $2 }' "$T/out.tsv" | sort -u | tr '\n' ' ')
[ "$read_set" = "issues-os " ] && ok "C6 no --project: only issues-os is read (rc $rc)" || bad "C6 projects read: '$read_set' rc $rc"

echo "tks_state reads the board through tracker_context"
rows linear-os=linear
: > "$T/vendor.log"
tks() { ( . "$H/bin/lib/ticket-state.sh"; out=$(tks_state "$H" "$1" "$2"); echo "$?:$out" ); }
[ "$(tks board-os 5)" = "0:closed" ] && [ "$(tks board-os 6)" = "1:" ] \
  && ok "C7 board: done is closed, a failed read rc 1" || bad "C7 $(tks board-os 5) $(tks board-os 6)"
[ "$(tks moved-os 5)" = "1:" ] && ok "C7 a board with a base and no token: rc 1" || bad "C7 no token: $(tks moved-os 5)"
grep -q '^curl https://moved.example' "$T/vendor.log" && bad "C7 the no-token project was read" || ok "C7 no read without a token"
before=$(grep -c '^curl ' "$T/vendor.log")
[ "$(tks linear-os 5)" = "1:" ] && [ "$(grep -c '^curl ' "$T/vendor.log")" = "$before" ] \
  && ok "C8 row linear: rc 1, 0 curl calls" || bad "C8 $(tks linear-os 5), curl calls $before -> $(grep -c '^curl ' "$T/vendor.log")"
other=$(grep -v -e '^curl https://board.example/api/board/tickets/5$' -e '^curl https://board.example/api/board/tickets/6$' "$T/vendor.log")
[ -z "$other" ] && ok "V no vendor call beyond the C7 fixture URLs" || bad "V vendor calls: $other"

echo "the ratchet scan"
# The scan of tests/tracker-direct-calls-ratchet.bh-7919-test.sh, on these two files.
hits=$(awk '
  /^[[:space:]]*#/ { next }
  /(^|[^A-Za-z0-9_])board_prefix([^A-Za-z0-9_]|$)/ ||
  (/gh_rest|gh api|gh-rest-shim/ && /\/issues/) ||
  /(^|[^A-Za-z0-9_-])gh issue([^A-Za-z0-9_]|$)/ ||
  (/curl/ && (/\/tickets/ || /\/boards/)) { print FILENAME ": " $0 }
' "$DIR/bin/lib/ticket-state.sh" "$DIR/bin/merged-build-closeout.sh")
[ -z "$hits" ] && ok "C9 no direct tracker call in the two files" || bad "C9 $hits"

echo "tracker-seam-callers.bh-8682: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
