#!/bin/bash
# tests/post-merge-verify.bh-3690-test.sh — BH-3690 C0: after a merge deploys,
# check that prod serves the merged sha. A match is silent. A mismatch pages once
# and files one ticket. deploy.kind=none is skipped, and a served sha nobody can
# read is recorded as unreadable, never paged as a mismatch (D11).
#
# Driven through the real bin/post-merge-verify.sh, bin/lib/post-merge-verify.sh,
# bin/alert-line.sh, bin/lib/deploy-kind.sh, bin/fleet-conf.sh and
# bin/deploy-verify.sh. gh, curl, beat.sh and bin/jobs-client.sh (settings and
# ledger, with an outage mode) are stubbed. The new files are copied only when
# present, so at the merge base the suite goes red on its assertions instead of
# aborting on a missing cp.
# Run from anywhere: bash tests/post-merge-verify.bh-3690-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

MERGED=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef
OTHER=0123456789abcdef0123456789abcdef01234567
KEY="tproj:app@$MERGED"

# ── the scratch harness: real scripts, stubbed edges ─────────────────────────
H="$T/h"
mkdir -p "$H/bin/lib" "$H/logs" "$H/env" "$T/fakebin" "$T/build" "$T/ledger"
cp "$DIR/bin/deploy-verify.sh" "$DIR/bin/prod-url.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/alert-line.sh" "$H/bin/"
cp "$DIR/bin/lib/deploy-kind.sh" "$H/bin/lib/"
[ -f "$DIR/bin/post-merge-verify.sh" ] && cp "$DIR/bin/post-merge-verify.sh" "$H/bin/"
[ -f "$DIR/bin/lib/post-merge-verify.sh" ] && cp "$DIR/bin/lib/post-merge-verify.sh" "$H/bin/lib/"
# BH-8962: the lib files its ticket through bin/lib/tracker/gh-issue-create.sh.
scratch_install_closure bin/lib/post-merge-verify.sh "$H" >/dev/null || exit 1
printf '#!/bin/bash\nexit 0\n' > "$H/bin/deploy-kind-resolve.sh"
chmod +x "$H/bin/"*.sh
printf 'tproj o/tproj https://tproj.example - 2 box-t 100.0.0.9\ncromford o/harness - - 3 box-t 100.0.0.9\n' > "$T/fleet.conf"
: > "$H/env/global.env"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> '"$T"'/beat.txt\nexit 0\n' > "$H/bin/beat.sh"; chmod +x "$H/bin/beat.sh"

# The jobs client. setting_get answers from $T/kind (absent -> rc 2, OUTAGE ->
# rc 1). The ledger is one file per key under $T/ledger; $T/ledger-outage makes
# both verbs answer rc 1. Every PUT is logged to $T/puts.txt.
cat > "$H/bin/jobs-client.sh" <<EOF
setting_get() {
  [ -f "$T/kind" ] || return 2
  local v; v=\$(cat "$T/kind")
  [ "\$v" = OUTAGE ] && return 1
  printf '%s' "\$v"
}
_lf() { printf '%s' "$T/ledger/\$(printf '%s|%s' "\$1" "\$2" | sha1sum | cut -c1-40)"; }
job_ledger_row() {
  [ -f "$T/ledger-outage" ] && return 1
  local f; f=\$(_lf "\$1" "\$2")
  [ -f "\$f" ] || return 2
  cat "\$f"
}
job_ledger_put() {
  [ -f "$T/ledger-outage" ] && return 1
  printf '%s %s %s %s\n' "\$1" "\$2" "\$3" "\${4:-}" >> "$T/puts.txt"
  jq -nc --arg s "\$3" --arg d "\${4:-}" '{status:\$s,detail:\$d}' > "\$(_lf "\$1" "\$2")"
}
EOF

# gh: every call logged to $T/gh.txt. The answers come from files:
#   $T/served   the deployment's .sha          $T/cmp     the compare .status
#   $T/search   the search hit's number ("" = no hit)
#   $T/create   ok (prints an issue URL) | fail (rc 1)
# The REST create (BH-8962) is answered from the `issue create` arm, through
# the adapter, so that arm still logs one `issue create` line per create.
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh.txt"
. "$DIR/tests/lib/gh-cli-rest-adapter.sh" || exit 1
gh_cli_rest_create "\$0" "\$@" && exit 0
case "\$*" in
  *deployments/*statuses*) echo success ;;
  *deployments/77*) cat "$T/served" 2>/dev/null ;;
  *deployments*) echo '[{"id":77,"environment":"production","created_at":"2026-09-14T03:00:00Z"}]' ;;
  *compare/*) [ -f "$T/cmp-fail" ] && { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }; cat "$T/cmp" 2>/dev/null ;;
  *search/issues*) cat "$T/search" 2>/dev/null ;;
  "issue create"*)
    [ "\$(cat "$T/create" 2>/dev/null)" = fail ] && { echo "gh: HTTP 502" >&2; exit 1; }
    echo "https://github.com/o/harness/issues/4242" ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
printf '#!/bin/bash\necho 200\n' > "$T/fakebin/curl"; chmod +x "$T/fakebin/curl"

RESET() {
  : > "$T/build/pipeline.log"; : > "$H/logs/ALERTS.log"; : > "$T/gh.txt"; : > "$T/beat.txt"; : > "$T/puts.txt"
  rm -rf "$T/ledger" "$H/state"; mkdir -p "$T/ledger"
  rm -f "$T/kind" "$T/ledger-outage" "$T/cmp-fail"
  : > "$T/search"; echo ok > "$T/create"; echo diverged > "$T/cmp"; printf '%s' "$MERGED" > "$T/served"
}
RUNENV() { env PATH="$T/fakebin:$PATH" HARNESS="$H" FLEET_CONF="$T/fleet.conf" CONSOLE_URL="" HARNESS_SECRET="" "$@"; }
PMV() { # PMV <served> [extra args] -> rc of the real CLI
  local s="$1"; shift
  RUNENV bash "$H/bin/post-merge-verify.sh" tproj --target app --merged "$MERGED" --served "$s" \
    --slug o/tproj --log "$T/build/pipeline.log" "$@" >/dev/null 2>"$T/pmv.err"
}
DV() { RUNENV bash "$H/bin/deploy-verify.sh" tproj o/tproj "$MERGED" "$T/build" >/dev/null 2>"$T/dv.err"; }
ALERTS() { grep -c '"kind":"alert"' "$T/beat.txt"; }
CREATES() { grep -c '^issue create' "$T/gh.txt"; }
ISSUEGH() { grep -c 'issue\|search/issues' "$T/gh.txt"; }
LSTATUS() { # the ledger status for KEY
  local f; f="$T/ledger/$(printf '%s|%s' post_merge_verify "$KEY" | sha1sum | cut -c1-40)"
  jq -r '.status' "$f" 2>/dev/null
}
LDETAIL() {
  local f; f="$T/ledger/$(printf '%s|%s' post_merge_verify "$KEY" | sha1sum | cut -c1-40)"
  jq -r '.detail' "$f" 2>/dev/null
}
JUDGE() { RUNENV bash -c '. "$HARNESS/bin/lib/post-merge-verify.sh" && pmv_judge "$@"' _ "$@" 2>/dev/null; }

# ============================================================================
# J. pmv_judge, the comparison rule (pure).
# ============================================================================
[ "$(JUDGE "$MERGED" "$MERGED" '')" = match ] && ok || bad "J1: equal shas must match"
[ "$(JUDGE "$MERGED" "${MERGED:0:7}" '')" = match ] && ok || bad "J2: a served short prefix must match"
[ "$(JUDGE "${MERGED:0:8}" "$MERGED" '')" = match ] && ok || bad "J2: a merged short prefix must match (inverse)"
[ "$(JUDGE "$MERGED" " DEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEF " '')" = match ] && ok || bad "J3: an uppercase, padded served sha must match (D17)"
[ "$(JUDGE "${MERGED^^}" "$MERGED" '')" = match ] && ok || bad "J3: an uppercase merged sha must match (inverse, D17)"
[ "$(JUDGE "$MERGED" "$OTHER" ahead)" = match ] && ok || bad "J4: served ahead of merged contains it (match)"
[ "$(JUDGE "$MERGED" "$OTHER" identical)" = match ] && ok || bad "J4: compare identical must match"
[ "$(JUDGE "$MERGED" "$OTHER" behind)" = mismatch ] && ok || bad "J5: served behind merged is a mismatch"
[ "$(JUDGE "$MERGED" "$OTHER" diverged)" = mismatch ] && ok || bad "J5: diverged is a mismatch"
[ "$(JUDGE "$MERGED" '' diverged)" = unreadable ] && ok || bad "J6: an empty served sha is unreadable, never a mismatch"
[ "$(JUDGE "$MERGED" null diverged)" = unreadable ] && ok || bad "J6: a null served sha is unreadable"
[ "$(JUDGE "$MERGED" 'zz12345' diverged)" = unreadable ] && ok || bad "J6: a non-hex served sha is unreadable"
[ "$(JUDGE "$MERGED" "$OTHER" '')" = unreadable ] && ok || bad "J6: an unreadable compare is unreadable, never a mismatch"
[ "$(JUDGE "$MERGED" "$OTHER" 'rate limited')" = unreadable ] && ok || bad "J6: an unknown compare status is unreadable"
KOUT=$(RUNENV bash -c '. "$HARNESS/bin/lib/post-merge-verify.sh" && pmv_key TProj App "${1^^}"' _ "$MERGED" 2>/dev/null)
[ "$KOUT" = "$KEY" ] && ok || bad "J7: pmv_key must lowercase all three parts (got '$KOUT')"
# D43: no root, no answer. pmv_act refuses and writes nothing.
env -u HARNESS -u H PATH="$T/fakebin:$PATH" bash -c '. "$1" && pmv_act tproj app "$2" "$3" mismatch "$4"' _ \
  "$H/bin/lib/post-merge-verify.sh" "$MERGED" "$OTHER" "$T/noroot.log" >/dev/null 2>&1; RC=$?
[ "$RC" != 0 ] && [ ! -s "$T/noroot.log" ] && ok || bad "J8: pmv_act with no HARNESS/H must return non-zero and write nothing (rc=$RC)"

# ============================================================================
# A. pmv_act through the CLI: page once, ticket once, record.
# ============================================================================
# A1: a mismatch -> one page, one ALERTS line, one ticket without ai-build.
RESET
PMV "$OTHER"; RC=$?
[ "$RC" = 0 ] && ok || bad "A1/C3: the CLI must exit 0 on a mismatch (rc=$RC)"
[ "$(ALERTS)" = 1 ] && ok || bad "A1: a mismatch must beat exactly one alert (got $(ALERTS): $(cat "$T/beat.txt"))"
grep -q "$KEY" "$T/beat.txt" && ok || bad "A1: the page must name the key $KEY"
[ "$(grep -c 'POST-MERGE VERIFY MISMATCH' "$H/logs/ALERTS.log")" = 1 ] && ok || bad "A1: exactly one ALERTS.log line (got: $(cat "$H/logs/ALERTS.log"))"
grep -q '"severity":"warn"' "$T/beat.txt" && ok || bad "A1: the page is severity warn"
[ "$(CREATES)" = 1 ] && ok || bad "A1: exactly one issue create (gh: $(cat "$T/gh.txt"))"
grep '^issue create' "$T/gh.txt" | grep -q -- '-R o/harness' && ok || bad "A1: the ticket goes to the harness repo from fleet.conf"
grep -q 'ai-build' <<<"$(grep '^issue create' "$T/gh.txt")" && bad "A1: the ticket must not carry ai-build" || ok
grep '^issue create' "$T/gh.txt" | grep -q -- '--label infra' && ok || bad "A1: the ticket carries the infra label"
[ "$(LSTATUS)" = ticketed ] && ok || bad "A1: the ledger must end ticketed (got '$(LSTATUS)')"
LDETAIL | grep -q 4242 && ok || bad "A1: the ledger detail names the issue number (got '$(LDETAIL)')"

# A2: the same mismatch again -> nothing new.
PMV "$OTHER"
[ "$(ALERTS)" = 1 ] && ok || bad "A2: a rerun must not page again (got $(ALERTS))"
[ "$(CREATES)" = 1 ] && ok || bad "A2: a rerun must not file again (got $(CREATES))"

# A3: the create fails -> one page, status paged. Fix it, rerun -> the ticket only.
RESET; echo fail > "$T/create"
PMV "$OTHER"
[ "$(ALERTS)" = 1 ] && ok || bad "A3: a failed create still pages once (got $(ALERTS))"
[ "$(LSTATUS)" = paged ] && ok || bad "A3: a failed create leaves the status paged (got '$(LSTATUS)')"
grep -q 'ticket not filed' "$T/build/pipeline.log" && ok || bad "A3: a failed create logs one line ($(cat "$T/build/pipeline.log"))"
echo ok > "$T/create"
PMV "$OTHER"
[ "$(ALERTS)" = 1 ] && ok || bad "A3: the rerun must not page again (got $(ALERTS))"
[ "$(CREATES)" = 2 ] && ok || bad "A3: the rerun files the ticket (creates=$(CREATES), one failed + one ok)"
[ "$(LSTATUS)" = ticketed ] && ok || bad "A3: the rerun ends ticketed (got '$(LSTATUS)')"

# A4: the ledger is down, the local marker says paged -> no new page.
RESET
PMV "$OTHER"        # pages, tickets, and writes the marker
: > "$T/beat.txt"; : > "$T/gh.txt"; touch "$T/ledger-outage"
PMV "$OTHER"
[ "$(ALERTS)" = 0 ] && ok || bad "A4: a ledger outage with a marker must not page again (got $(ALERTS))"
[ "$(CREATES)" = 0 ] && ok || bad "A4: a ticketed marker must not file again (got $(CREATES))"
# ...and a marker that only says paged still pages nothing, but files the ticket.
RESET; echo fail > "$T/create"
PMV "$OTHER"
: > "$T/beat.txt"; echo ok > "$T/create"; touch "$T/ledger-outage"
PMV "$OTHER"
[ "$(ALERTS)" = 0 ] && ok || bad "A4: a paged marker under a ledger outage must not page again (got $(ALERTS))"
[ "$(CREATES)" = 2 ] && ok || bad "A4: a paged marker goes on to the ticket (creates=$(CREATES))"

# A5: the search already finds the ticket -> no create, status ticketed #999.
RESET; echo 999 > "$T/search"
PMV "$OTHER"
[ "$(CREATES)" = 0 ] && ok || bad "A5: an existing ticket must not be filed again (got $(CREATES))"
[ "$(LSTATUS)" = ticketed ] && ok || bad "A5: an existing ticket records ticketed (got '$(LSTATUS)')"
LDETAIL | grep -q 999 && ok || bad "A5: the ledger detail names #999 (got '$(LDETAIL)')"
grep 'search/issues' "$T/gh.txt" | grep -q 'o/harness' && ok || bad "A5: the search is on the harness repo ($(cat "$T/gh.txt"))"

# A6: a match is silent: no beat, no issue gh call, ledger verified.
RESET
PMV "$MERGED"
[ "$(ALERTS)" = 0 ] && ok || bad "A6: a match must not page (got $(ALERTS))"
[ -s "$H/logs/ALERTS.log" ] && bad "A6: a match must not write ALERTS.log" || ok
[ "$(ISSUEGH)" = 0 ] && ok || bad "A6: a match must make no issue gh call ($(cat "$T/gh.txt"))"
[ "$(LSTATUS)" = verified ] && ok || bad "A6: a match records verified (got '$(LSTATUS)')"
[ "$(grep -c 'post-merge-verify OK' "$T/build/pipeline.log")" = 1 ] && ok || bad "A6: a match logs one OK line ($(cat "$T/build/pipeline.log"))"

# A7: an empty served sha is unreadable: no beat, no gh, ledger unreadable.
RESET
PMV ""
[ "$(ALERTS)" = 0 ] && ok || bad "A7: unreadable must not page (got $(ALERTS))"
[ -s "$T/gh.txt" ] && bad "A7: unreadable must make no gh call ($(cat "$T/gh.txt"))" || ok
[ "$(LSTATUS)" = unreadable ] && ok || bad "A7: unreadable is recorded (got '$(LSTATUS)')"
# ...and a compare that fails (404/403/rate limit) is unreadable too.
RESET; touch "$T/cmp-fail"
PMV "$OTHER"
[ "$(ALERTS)" = 0 ] && ok || bad "A7: a failed compare must not page (got $(ALERTS))"
[ "$(LSTATUS)" = unreadable ] && ok || bad "A7: a failed compare is unreadable (got '$(LSTATUS)')"

# ============================================================================
# C. The CLI: deploy.kind, compare, exit code.
# ============================================================================
# C1: kind=none plus a mismatch fixture -> skip before gh, ledger and page.
RESET; printf none > "$T/kind"
PMV "$OTHER"; RC=$?
[ "$RC" = 0 ] && ok || bad "C1: kind=none exits 0 (rc=$RC)"
[ "$(ALERTS)" = 0 ] && ok || bad "C1: kind=none must not page"
[ -s "$T/gh.txt" ] && bad "C1: kind=none must make no gh call ($(cat "$T/gh.txt"))" || ok
[ -s "$T/puts.txt" ] && bad "C1: kind=none must write no ledger row ($(cat "$T/puts.txt"))" || ok
grep -q 'SKIP (deploy.kind=none)' "$T/build/pipeline.log" && ok || bad "C1: kind=none logs one SKIP line ($(cat "$T/build/pipeline.log"))"
# C2: a settings outage is never a skip.
RESET; printf OUTAGE > "$T/kind"
PMV "$OTHER"
[ "$(ALERTS)" = 1 ] && ok || bad "C2: a kind outage still verifies (alerts=$(ALERTS))"
# C4: compare behind -> mismatch; compare ahead -> silent.
RESET; echo behind > "$T/cmp"
PMV "$OTHER"
[ "$(ALERTS)" = 1 ] && ok || bad "C4: compare behind is a mismatch (alerts=$(ALERTS))"
grep 'compare/' "$T/gh.txt" | grep -q "repos/o/tproj/compare/$MERGED...$OTHER" && ok || bad "C4: the compare is merged...served on the project repo ($(cat "$T/gh.txt"))"
RESET; echo ahead > "$T/cmp"
PMV "$OTHER"
[ "$(ALERTS)" = 0 ] && ok || bad "C4: compare ahead is silent (alerts=$(ALERTS))"
[ "$(LSTATUS)" = verified ] && ok || bad "C4: compare ahead records verified (got '$(LSTATUS)')"

# ============================================================================
# D. The first real caller: bin/deploy-verify.sh.
# ============================================================================
# D1: the deployment serves the merged sha -> OK line, no page.
RESET
DV; RC=$?
[ "$RC" = 0 ] && ok || bad "D1: deploy-verify exits 0 (rc=$RC, $(cat "$T/dv.err"))"
grep -q 'deploy-verify OK' "$T/build/pipeline.log" && ok || bad "D1: deploy-verify's own OK line is unchanged"
grep -q 'post-merge-verify OK' "$T/build/pipeline.log" && ok || bad "D1: deploy-verify must run the contract ($(cat "$T/build/pipeline.log"))"
grep -q 'deployments/77 ' "$T/gh.txt" && ok || bad "D1: the served sha is read off deployment 77 ($(cat "$T/gh.txt"))"
[ "$(ALERTS)" = 0 ] && ok || bad "D1: a match through deploy-verify must not page"
# D2: the deployment serves another sha, diverged -> one page, one ticket, rc 0.
RESET; printf '%s' "$OTHER" > "$T/served"; echo diverged > "$T/cmp"
DV; RC=$?
[ "$RC" = 0 ] && ok || bad "D2: a mismatch never changes deploy-verify's verdict (rc=$RC)"
[ "$(ALERTS)" = 1 ] && ok || bad "D2: a mismatch through deploy-verify pages once (got $(ALERTS))"
[ "$(CREATES)" = 1 ] && ok || bad "D2: a mismatch through deploy-verify files one ticket (got $(CREATES))"
# D3: kind=none -> deploy-verify exits above the contract, no deployment read.
RESET; printf none > "$T/kind"
DV
grep -q 'deployments/77' "$T/gh.txt" && bad "D3: kind=none must not read deployment 77" || ok
grep -q 'post-merge-verify' "$T/build/pipeline.log" && bad "D3: kind=none must not reach the contract ($(cat "$T/build/pipeline.log"))" || ok

echo "post-merge-verify.bh-3690: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
