#!/bin/bash
# tests/mc/no-human-park.bh-4145-test.sh — BH-4145: under lead_authority_mode
# lane (the default: no row) the conductor never parks a protected-path PR as
# NEEDS_HUMAN_VERDICT; it enqueues it like any other PR. A stored human mode
# row (refused since BH-5035) holds the row, it never parks. CI is not bypassed.
#
# WHAT IS DRIVEN. The real bin/merge-conductor.sh over a Mergify repo through
# tests/lib/nhv-conductor-fixture.sh, with two swaps the fixture does not make
# (the fixture itself is untouched):
#   * its verdict-status.sh stub is replaced by one that sources the REAL
#     bin/lib/lead-authority.sh, with setting_get answering $T/set/<key> (no
#     file = no row, rc 2) and _jobs_req answering GET /api/lead-protected-paths
#     from one lead_protected_paths row governing example-org/mgfy-os on
#     .mergify.yml (tests/lib/lpp-stub.sh; every other path still reaches the
#     real jobs client). vs_publish / vs_context stay stubs (logged to vs-calls.txt);
#   * its fake gh is wrapped: pulls/<n>/files answers $T/files.json ($T/files500
#     = HTTP 500), actions/runs answers $T/ci (success|failure); everything else
#     reaches the fixture's gh. $HARNESS/bin/lane-alert.sh records to $T/alerts.
#   N1 protected PR, green CI, no mode row -> enqueued (QUEUED, labelled, success
#      published), never NEEDS_HUMAN_VERDICT, nobody paged
#   N2 the same with lead_authority_mode=human -> la_decide rc 2: the row stays
#      READY under the BH-2199 hold (MERGE_HELD naming the BH-5035 reason), not
#      NEEDS_HUMAN_VERDICT; no label, no success, no human-needed page
#   N3 N2's held row, the human row deleted -> one tick enqueues, no page
#   N4 lane + red CI -> not enqueued, no success published
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/mc/no-human-park.bh-4145-test.sh
# TEST-CHANGE BH-4140: globs come from the DB, not the TSV
# TEST-CHANGE BH-5035: a stored lead_authority_mode=human row is refused (rc 2 hold), it no longer parks NEEDS_HUMAN_VERDICT
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/../lib/scratch.sh" || exit 1
# shellcheck source=tests/lib/lpp-stub.sh
. "$(dirname "$0")/../lib/lpp-stub.sh" || exit 1
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/gh-list-bridge.sh" || exit 1
DIR=$(cd "$(dirname "$0")/../.." && pwd)
# shellcheck source=tests/lib/verdict-fixture.sh
. "$(dirname "$0")/../lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
# shellcheck source=tests/lib/nhv-conductor-fixture.sh
. "$(dirname "$0")/../lib/nhv-conductor-fixture.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "flock missing — skipping"; exit 0; }

nhvf_setup || { echo "FAIL: fixture setup"; exit 1; }
cp "$DIR/bin/lib/lead-authority.sh" "$T/h/bin/lib/lead-authority.sh" || exit 1
mkdir -p "$T/set"
LPP="$T/lpp.json"; LPPDOWN="$T/lpp-down"
lpp_install "$T" "$LPP" "$LPPDOWN"
lpp_set "$LPP" example-org/mgfy-os .mergify.yml
# The conductor sources bin/jobs-client.sh before this stub, so the real
# _jobs_req is kept as _jobs_req_real and only the rows route is answered here.
cat > "$T/h/bin/lib/verdict-status.sh" <<EOF
. "$T/h/bin/lib/lead-authority.sh"
$(declare -f lpp_install lpp_jobs_req)
eval "\$(declare -f _jobs_req 2>/dev/null | sed '1s/^_jobs_req /_jobs_req_real /')"
_jobs_req() {
  case "\$2" in
    /api/lead-protected-paths*) lpp_jobs_req "$LPP" "$LPPDOWN" "\$@" ;;
    *) command -v _jobs_req_real >/dev/null 2>&1 || return 1; _jobs_req_real "\$@" ;;
  esac
}
setting_get() {
  [ -f "$T/set/\$1" ] || return 2
  cat "$T/set/\$1"
}
vs_publish() { printf '%s\n' "\$*" >> "$T/vs-calls.txt"; return 0; }
vs_context() { echo lead-verdict; }
EOF
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s"\nexit 0\n' "$T/alerts" > "$T/h/bin/lane-alert.sh"
chmod +x "$T/h/bin/lane-alert.sh"
mv "$T/fakebin/gh" "$T/fakebin/gh.fixture"
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
case "\$*" in
  *"api -i -X GET repos/"*"/pulls/"*"/files"*)
    printf '%s\n' "\$*" >> "$T/gh-calls.txt"
    [ -e "$T/files500" ] && { restpr --raw 500 '{"message":"boom"}'; exit 0; }
    case "\$*" in *"&page=1"*) restpr --raw 200 "\$(cat "$T/files.json")" ;; *) restpr --raw 200 '[]' ;; esac
    exit 0 ;;
  *"actions/runs?head_sha="*)
    printf '%s\n' "\$*" >> "$T/gh-calls.txt"
    restpr --runs "completed|\$(cat "$T/ci" 2>/dev/null || echo success)"; exit 0 ;;
esac
exec "$T/fakebin/gh.fixture" "\$@"
EOF
chmod +x "$T/fakebin/gh"
echo '[{"filename":"README.md"},{"filename":".mergify.yml"}]' > "$T/files.json"

H41=aaaaaaaa00aaaaaaaaaaaaaaaaaaaaaaaaaaaa41
nhvf_pr 41 "$H41"
state() { nhvf_field 41 2; }
labelled() { grep -qxF merge-queue "$T/labels-41"; }
published() { grep -c "$H41 success" "$T/vs-calls.txt" 2>/dev/null; }
nalerts() { local c; c=$(grep -c -- "--id lead-human-needed-" "$T/alerts" 2>/dev/null); echo "${c:-0}"; }

# reset <mode|-> — a fresh READY row (seeded by a tick whose files read fails:
# la_decide rc 2, the hold), then the mode row and green CI.
reset() {
  rm -f "$T/set"/* "$T/alerts" "$T/ci"
  scratch_rm "$T/h/state/lead-authority"
  touch "$T/files500"; nhvf_reset; rm -f "$T/files500"
  [ "$1" = - ] || printf '%s' "$1" > "$T/set/lead_authority_mode"
}
why() { printf 'state %s; log: %s; err: %s' "$(state)" "$(grep -F '#41' "$CLOG" | tail -3 | tr '\n' '|')" "$(tail -3 "$T/tick.err" 2>/dev/null | tr '\n' '|')"; }

# ── N1 ──────────────────────────────────────────────────────────────────────
reset -
nhvf_tick
[ "$(state)" != NEEDS_HUMAN_VERDICT ] && ok || bad "N1 lane: a protected PR is never NEEDS_HUMAN_VERDICT ($(why))"
[ "$(state)" = QUEUED ] && labelled && ok || bad "N1 lane: the row is enqueued (QUEUED, labelled) ($(why))"
[ "$(published)" -ge 1 ] && ok || bad "N1 lane: the conductor publishes success on the head ($(cat "$T/vs-calls.txt"))"
[ "$(nalerts)" = 0 ] && ok || bad "N1 lane: nobody is paged for a human verdict ($(cat "$T/alerts" 2>/dev/null))"
grep -q "pulls/41/files" "$T/gh-calls.txt" && ok || bad "N1 lane: la_decide really read the files (no read logged)"

# ── N2 ──────────────────────────────────────────────────────────────────────
reset human
nhvf_tick
[ "$(state)" = READY ] && ok || bad "N2 human: a refused mode row holds the row READY, never NEEDS_HUMAN_VERDICT ($(why))"
grep -F '#41' "$CLOG" | grep -q "MERGE_HELD: .*the lead authority could not be decided (the mode row lead_authority_mode reads 'human', a value BH-5035 retired" \
  && ok || bad "N2 human: the hold names the BH-5035 reason ($(why))"
labelled && bad "N2 human: no label" || ok
[ "$(published)" = 0 ] && ok || bad "N2 human: no success published ($(cat "$T/vs-calls.txt"))"
[ "$(nalerts)" = 0 ] && ok || bad "N2 human: no human-needed page ($(cat "$T/alerts" 2>/dev/null))"

# ── N3 ──────────────────────────────────────────────────────────────────────
# N2's held row, the human row deleted: the next tick enqueues it.
rm -f "$T/set/lead_authority_mode" "$T/alerts"; nhvf_clear
nhvf_tick
[ "$(state)" = QUEUED ] && labelled && ok || bad "N3 a held row under lane is enqueued in one tick ($(why))"
[ "$(nalerts)" = 0 ] && ok || bad "N3 no human-verdict page on the way out ($(cat "$T/alerts" 2>/dev/null))"

# ── N4 ──────────────────────────────────────────────────────────────────────
reset -
echo failure > "$T/ci"
nhvf_tick
[ "$(state)" != QUEUED ] && ! labelled && ok || bad "N4 lane + red CI is not enqueued ($(why))"
[ "$(published)" = 0 ] && ok || bad "N4 lane + red CI: no success published ($(cat "$T/vs-calls.txt"))"

echo "no-human-park: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
