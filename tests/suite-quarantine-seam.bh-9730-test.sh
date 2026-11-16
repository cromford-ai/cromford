#!/bin/bash
# tests/suite-quarantine-seam.bh-9730-test.sh — BH-9730: sqh_file in
# bin/lib/suite-quarantine-hub.sh creates the repair issue through the tracker
# seam (tracker_create, bin/lib/tracker.sh + bin/lib/tracker/github-issues.sh),
# not through a direct `gh_rest POST repos/<slug>/issues`. The BH-7919 ratchet
# (tests/tracker-direct-calls-ratchet.bh-7919-test.sh) went red on main when
# BH-9697 added the direct call.
#
# PINNED. The REAL lib, the REAL gh-rest libs and the REAL tracker files in a
# scratch HARNESS. gh is a PATH stub that logs every call; bin/jobs-client.sh
# is a fake that logs and answers {"updated":1}. No network. One scratch dir
# per case.
#   S1 happy path: one `POST repos/<slug>/issues --input <file>`; the payload
#      has the title, the ai-build label and the marker; the link follows the
#      POST; `filed #41`
#   S2 the POST carries no title= / body=@ / labels[]= form argument
#   S3 tracker.sh missing: no POST, no link, rc 0, the seam failure line
#   S4 the POST answers 500: no link, rc 0, `failed (HTTP 500)`
#   S5 a 201 with no .number: no link, rc 0, the same failure line
#   S6 DRY=1: no gh call, tracker.sh not sourced, the `would:` line
#   S7 an open issue carries the marker: no POST, one link (reuse)
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/suite-quarantine-seam.bh-9730-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
SLUG=example-org/cromford
SUITE=tests/a-test.sh
MARK="<!-- harness-suite-quarantine: $SUITE -->"

# mk <case> — a scratch HARNESS with the real libs, the fake client and a gh stub.
mk() {
  local h="$T/$1/h" st="$T/$1/st"
  mkdir -p "$h/bin/lib/tracker" "$T/$1/bin" "$T/$1/tmp" "$st"
  for f in gh-rest.sh gh-rest-list.sh gh-rest-var.sh suite-quarantine-hub.sh tracker.sh; do
    ln -sf "$DIR/bin/lib/$f" "$h/bin/lib/$f"
  done
  ln -sf "$DIR/bin/lib/tracker/github-issues.sh" "$h/bin/lib/tracker/github-issues.sh"
  printf '#!/bin/bash\necho "JOBS $*" >> %q\necho %s\n' "$st/calls" "'{\"updated\":1}'" > "$h/bin/jobs-client.sh"
  printf 'tests/a-test.sh\t-\t%s\t2026-11-10T00:00:00Z\n' "$(printf 'a%.0s' {1..40})" > "$T/$1/rows"
  cat > "$T/$1/bin/gh" <<EOF
#!/bin/bash
echo "GH \$*" >> "$st/calls"
shift; M=GET; P=
while [ \$# -gt 0 ]; do case "\$1" in -i) shift ;; -X) M="\$2"; shift 2 ;; *) P="\$1"; shift; break ;; esac; done
pl=; nx=
for a in "\$@"; do [ "\$nx" = 1 ] && { pl="\$a"; nx=; continue; }; [ "\$a" = --input ] && nx=1; done
reply() { printf 'HTTP/2 %s X\r\n\r\n%s\n' "\$1" "\${2:-}"; }
case "\$M \${P%%\?*}" in
  "GET repos/$SLUG/issues") reply 200 "\$(cat "$st/issues.json" 2>/dev/null || echo '[]')" ;;
  "POST repos/$SLUG/issues")
    [ -n "\$pl" ] && cp "\$pl" "$st/payload.json"
    [ -f "$st/post.fail" ] && { reply 500 '{}'; exit 0; }
    [ -f "$st/post.nonum" ] && { reply 201 '{"html_url":"x"}'; exit 0; }
    reply 201 '{"number":41}' ;;
  *) reply 500 '{}' ;;
esac
EOF
  chmod +x "$T/$1/bin/gh"
}
# run <case> [dry] — source the lib in a subshell and call sqh_file once.
# Writes RC; <case>/out is the say log; <case>/defined says whether
# tracker_create was defined after the call.
run() {
  local c="$1" d="${2:-0}"
  ( export HARNESS="$T/$c/h" PATH="$T/$c/bin:$PATH" TMPDIR="$T/$c/tmp"
    unset H TRK_DRY TRK_LOG GH_TOKEN
    for f in gh-rest.sh gh-rest-list.sh gh-rest-var.sh suite-quarantine-hub.sh; do
      # shellcheck source=/dev/null
      . "$HARNESS/bin/lib/$f" || exit 9
    done
    say() { printf '%s\n' "$*" >> "$T/$c/out"; }
    _ft_do() { shift; "$@"; }
    TMPD="$T/$c/tmp"; DRY="$d"
    sqh_file "$SLUG" "$T/$c/rows" 3; r=$?
    if declare -F tracker_create >/dev/null 2>&1; then echo yes; else echo no; fi > "$T/$c/defined"
    exit "$r" ) > "$T/$c/stdout" 2>&1
  RC=$?
  touch "$T/$c/out" "$T/$c/st/calls"
}
posts() { grep -c "^GH api -i -X POST repos/$SLUG/issues" "$T/$1/st/calls"; }
links() { grep -c '^JOBS suite-quarantine-issue ' "$T/$1/st/calls"; }

# ── S1 / S2: the happy path goes through the seam ────────────────────────────
mk s1; run s1
[ "$RC" = 0 ] && [ "$(posts s1)" = 1 ] && grep -qE "^GH api -i -X POST repos/$SLUG/issues --input [^ ]+\$" "$T/s1/st/calls" && ok \
  || bad "S1 one seam POST with --input (rc $RC): $(cat "$T/s1/st/calls")"
jq -e --arg t "[suite-quarantine] $SUITE" '.title == $t and .labels == ["ai-build"]' "$T/s1/st/payload.json" >/dev/null 2>&1 && ok \
  || bad "S1 the payload title/labels: $(cat "$T/s1/st/payload.json" 2>/dev/null)"
jq -e --arg m "$MARK" '.body | contains($m)' "$T/s1/st/payload.json" >/dev/null 2>&1 && ok || bad "S1 the payload body has no marker"
LP=$(grep -n "^GH api -i -X POST repos/$SLUG/issues" "$T/s1/st/calls" | cut -d: -f1); LL=$(grep -n '^JOBS suite-quarantine-issue ' "$T/s1/st/calls" | cut -d: -f1)
[ -n "$LP" ] && [ -n "$LL" ] && [ "$LP" -lt "$LL" ] && [ "$(links s1)" = 1 ] && grep -q '"repair_issue":41' "$T/s1/st/calls" && ok \
  || bad "S1 the POST (line $LP) before one link (line $LL): $(cat "$T/s1/st/calls")"
grep -qxF "suite-quarantine: filed #41 for $SUITE" "$T/s1/out" && ok || bad "S1 no filed line: $(cat "$T/s1/out")"
# S2: the near miss of the old shape: no form-arg create.
! grep -qE 'title=|body=@|labels\[\]=' <<<"$(grep "^GH api -i -X POST repos/$SLUG/issues" "$T/s1/st/calls")" && ok \
  || bad "S2 the POST still sends form args: $(grep POST "$T/s1/st/calls")"

# ── S3: the seam is not loadable ─────────────────────────────────────────────
mk s3; rm -f "$T/s3/h/bin/lib/tracker.sh"; run s3
[ "$RC" = 0 ] && [ "$(posts s3)" = 0 ] && [ "$(links s3)" = 0 ] && grep -q 'tracker seam bin/lib/tracker.sh not loadable' "$T/s3/out" \
  && grep -q 'the row stays NULL' "$T/s3/out" && ! grep -q 'filed #' "$T/s3/out" && ok \
  || bad "S3 seam missing (rc $RC): $(cat "$T/s3/out"); $(cat "$T/s3/st/calls")"

# ── S4: the create answers 500 ───────────────────────────────────────────────
mk s4; touch "$T/s4/st/post.fail"; run s4
[ "$RC" = 0 ] && [ "$(posts s4)" = 1 ] && [ "$(links s4)" = 0 ] && grep -qF "ticket create for $SUITE failed (HTTP 500)" "$T/s4/out" && ! grep -q 'filed #' "$T/s4/out" && ok \
  || bad "S4 HTTP 500 (rc $RC): $(cat "$T/s4/out"); $(cat "$T/s4/st/calls")"

# ── S5: a 201 with no .number ────────────────────────────────────────────────
mk s5; touch "$T/s5/st/post.nonum"; run s5
[ "$RC" = 0 ] && [ "$(posts s5)" = 1 ] && [ "$(links s5)" = 0 ] && grep -qF "ticket create for $SUITE failed (HTTP 201)" "$T/s5/out" && ! grep -q 'filed #' "$T/s5/out" && ok \
  || bad "S5 201 without .number (rc $RC): $(cat "$T/s5/out"); $(cat "$T/s5/st/calls")"

# ── S6: a dry run sends nothing and sources nothing ──────────────────────────
mk s6; run s6 1
[ "$RC" = 0 ] && [ "$(grep -c '^GH ' "$T/s6/st/calls")" = 1 ] && grep -q "^GH api -i -X GET repos/$SLUG/issues" "$T/s6/st/calls" \
  && [ "$(posts s6)" = 0 ] && [ "$(links s6)" = 0 ] && [ "$(cat "$T/s6/defined")" = no ] && grep -q '^would: suite-quarantine issue' "$T/s6/out" && ok \
  || bad "S6 dry run (rc $RC, tracker_create defined: $(cat "$T/s6/defined")): $(cat "$T/s6/out"); $(cat "$T/s6/st/calls")"

# ── S7: an open issue with the marker is reused ──────────────────────────────
mk s7; jq -nc --arg m "$MARK" '[{number: 77, body: ($m + "\nold")}]' > "$T/s7/st/issues.json"; run s7
[ "$RC" = 0 ] && [ "$(posts s7)" = 0 ] && [ "$(links s7)" = 1 ] && grep -q '"repair_issue":77' "$T/s7/st/calls" && grep -q "reuses open ticket #77" "$T/s7/out" && ok \
  || bad "S7 reuse (rc $RC): $(cat "$T/s7/out"); $(cat "$T/s7/st/calls")"

echo "suite-quarantine-seam.bh-9730: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
