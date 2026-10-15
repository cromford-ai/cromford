#!/bin/bash
# tests/lead-authority-sig.bh-4090-test.sh — BH-4090: the UNMODIFIED shell
# reader (bin/lib/lead-authority.sh la_decide -> setting_get -> _jobs_req) on
# the worker's new answers for an unproven lead_* row under sig enforce. The
# real bin/lib/jobs/*.sh, lead-authority.sh and catalog; only curl (the worker,
# answers by path from $W/<key>.code + $W/<key>.json) and gh (REST) are stubbed.
#   LS1  mode human; lead_authority answers the effective `human` -> la_decide lead rc 1
#   LS2  the lead_protected_paths read answers 409 with no fresh cache -> la_decide rc 2
#        HOLD (BH-4148: was the extras row); the extras 409 is still setting_get rc 9
#   LS3  control: a proven lane, no extras, unprotected files -> rc 0
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lead-authority-sig.bh-4090-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/lpp-stub.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

IN=example-org/cromford
HEAD=aaaaaaaa11111111111111111111111111111111
K=lead_authority.example-org.cromford
X=lead_protected_paths_extra.example-org.cromford
M=lead_authority_mode.example-org.cromford
G="$T/gh"; W="$T/worker"; mkdir -p "$G" "$W" "$T/fakebin" "$T/tmp"
cp "$DIR/tests/lib/rest-emit.sh" "$T/fakebin/restpr"; chmod +x "$T/fakebin/restpr"

cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
case "\$*" in
  *"api -i -X GET repos/"*"/pulls/"[0-9]*"/files"*)
    case "\$*" in *"&page=1"*) restpr --raw 200 '[{"filename":"README.md"}]' ;; *) restpr --raw 200 '[]' ;; esac ;;
  *"api -i -X GET repos/"*"/pulls/"[0-9]*) restpr OPEN "$HEAD" ;;
  *) echo "" ;;
esac
exit 0
EOF
cat > "$T/fakebin/curl" <<EOF
#!/bin/bash
url=""
for a in "\$@"; do case "\$a" in http*) url="\$a" ;; esac; done
p="\${url#https://jobs.test}"
printf 'GET %s\n' "\$p" >> "$W/log"
case "\$p" in /api/lead-protected-paths*) lpp-answer GET "\$url"; exit 0 ;; esac
k="\${p#/api/settings/}"
if [ -f "$W/\$k.code" ]; then printf '%s\n%s' "\$(cat "$W/\$k.json")" "\$(cat "$W/\$k.code")"
else printf '%s\n%s' '{"error":"no such setting"}' 404; fi
EOF
chmod +x "$T/fakebin/gh" "$T/fakebin/curl"

H="$T/h"; mkdir -p "$H/logs" "$H/state" "$H/catalog"
for f in bin/jobs-client.sh bin/lib/gh-rest.sh bin/lib/lead-authority.sh; do
  scratch_install_closure "$f" "$H" >/dev/null || exit 1
done
# TEST-CHANGE BH-4148 (merge of main): the lead protected paths come from the
# lead_protected_paths rows (tests/lib/lpp-stub.sh), not the deleted TSV. The rows
# are the cromford globs the TSV held (the fixture).
LPPF="$T/lpp.json"; LPPDOWN="$T/lpp-down"
set -f; lpp_set "$LPPF" example-org/cromford $(cat "$DIR/tests/fixtures/lead-protected-paths.bh-4148.txt"); set +f
lpp_install "$T/fakebin" "$LPPF" "$LPPDOWN"
printf '#!/bin/bash\nexit 0\n' > "$H/bin/lane-alert.sh"; chmod +x "$H/bin/lane-alert.sh"

export PATH="$T/fakebin:$PATH" HARNESS="$H" HARNESS_SECRET=s JOBS_URL=https://jobs.test JOBS_RETRIES=0 \
  JOBS_BOX=box-hub TMPDIR="$T/tmp" GH_APP_TOKENS=0 JOBS_ALERT=0
unset GH_TOKEN

reset() { rm -f "$W"/*; }
answer() { printf '%s' "$2" > "$W/$1.code"; printf '%s' "$3" > "$W/$1.json"; }
decide() {
  ( . "$H/bin/jobs-client.sh" >/dev/null 2>&1; . "$H/bin/lib/gh-rest.sh" 2>/dev/null
    . "$H/bin/lib/lead-authority.sh" 2>/dev/null
    la_decide "$IN" 7 "$HEAD" lead; echo "rc=$? reason=${LA_REASON:-}" ) 2>"$T/err"
}

# LS1 — the worker's effective human for an unproven authority row (the
# authority row only bites under lead_authority_mode=human, BH-4145)
reset
answer "$M" 200 "{\"key\":\"$M\",\"setting\":{\"key\":\"$M\",\"value\":\"human\"},\"source\":\"settings\"}"
answer "$K" 200 "{\"key\":\"$K\",\"setting\":{\"key\":\"$K\",\"value\":\"human\",\"unproven\":true,\"stored_value\":\"lane\"},\"source\":\"unproven\"}"
R=$(decide)
case "$R" in "rc=1 reason=lane authority revoked"*) ok ;; *) bad "LS1 want rc 1 lane authority revoked, got: $R" ;; esac

# LS2 — TEST-CHANGE BH-4148: the extras settings row is gone (a protected glob is
# a lead_protected_paths row now), so the HOLD on an unreadable extras row
# becomes the same fail-closed rule on the new read: the rows answer the 409 and
# no cache is fresh -> la_decide rc 2 HOLD.
reset; rm -f "$H/state/lead-authority/"globs-*.cache; printf 409 > "$LPPDOWN"
R=$(decide)
case "$R" in "rc=2 reason=the protected paths of $IN could not be read"*) ok ;; *) bad "LS2 want rc 2 HOLD, got: $R" ;; esac
grep -q '^GET .*/api/lead-protected-paths' "$LPPF.log" && ok || bad "LS2 the protected paths were never read: $(cat "$LPPF.log" 2>/dev/null)"
rm -f "$LPPDOWN"
# the 409 an unproven extras row still gets is setting_get rc 9 through the real _jobs_req
answer "$X" 409 "{\"error\":\"$X signature does not verify; re-PUT it with the human token\",\"key\":\"$X\"}"
RC=$( ( . "$H/bin/jobs-client.sh" >/dev/null 2>&1; setting_get "$X" >/dev/null; echo $? ) 2>/dev/null)
[ "$RC" = 9 ] && ok || bad "LS2 setting_get rc $RC (want 9)"

# LS3 — control: a proven lane, no extras row, an unprotected file
reset
answer "$K" 200 "{\"key\":\"$K\",\"setting\":{\"key\":\"$K\",\"value\":\"lane\"},\"source\":\"settings\"}"
R=$(decide)
case "$R" in "rc=0"*) ok ;; *) bad "LS3 want rc 0, got: $R ($(cat "$T/err"))" ;; esac

echo "lead-authority-sig.bh-4090: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
